import 'dart:async' show StreamSubscription, Timer;
import 'dart:math' show max, min;
import 'dart:ui' as ui show Image, lerpDouble;

import 'package:PiliPlus/common/style.dart';
import 'package:PiliPlus/common/widgets/image/network_img_layer.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/services/mini_player/mini_player_host_layer.dart';
import 'package:PiliPlus/services/mini_player/mini_player_policy.dart';
import 'package:PiliPlus/services/mini_player/mini_player_session.dart';
import 'package:PiliPlus/services/shutdown_timer_service.dart';
import 'package:PiliPlus/utils/duration_utils.dart';
import 'package:flutter/foundation.dart' show clampDouble;
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// 应用内小窗，仅负责展示与手势，状态由 [miniPlayerSession] 驱动
class AppMiniPlayerOverlay extends StatefulWidget {
  const AppMiniPlayerOverlay({
    required this.child,
    super.key,
  });

  final Widget child;

  @override
  State<AppMiniPlayerOverlay> createState() => _AppMiniPlayerOverlayState();
}

class _AppMiniPlayerOverlayState extends State<AppMiniPlayerOverlay>
    with SingleTickerProviderStateMixin {
  static const double _margin = 16;
  static const double _radius = 8;
  static const double _edgeGestureDistance = 72;
  static const double _flingVelocity = 650;
  static const double _restoreVelocity = 420;
  static const double _snapVelocity = 420;
  static const double _restoreVerticalRatio = 0.75;
  static const _fadeOutDuration = Duration(milliseconds: 120);

  /// 展开结束时背景变暗的程度
  static const double _backdropDim = 0.24;

  /// 小窗黑边处的遮罩在展开进度达到此值时完全淡去
  static const double _maskFadeEnd = 0.4;

  /// 详情页播放器底边进度条在播放器内的高度，对应上游 `PLVideoPlayer` 中
  /// 进度条的位置（`bottom: -2.2`）与高度（`2 * thumbRadius`，即 5）
  static const double _progressBarInset = 2.8;

  final _session = miniPlayerSession;

  /// 唯一的动画驱动：小窗的位置、大小、圆角与详情页的展开、收起共用同一进度
  late final AnimationController _animation;
  late final List<StreamSubscription> _subscriptions;

  bool _visible = false;

  /// 小窗隐藏后保留一帧再移除，不与展开的交接落在同一帧
  bool _retiring = false;

  /// 小窗飞到播放器的位置后淡出
  bool _fadingOut = false;

  /// 过渡起点，null 表示静止
  Rect? _from;

  /// 进入时锁定的终点，过渡期间布局变化不改变终点
  Rect? _frozenTarget;
  double _fromRadius = _radius;
  Rect? _lastRect;
  double _lastRadius = _radius;
  Rect? _placement;
  Rect? _restoreTarget;
  double? _preferredWidth;
  Rect? _gestureStartRect;
  Offset? _gestureStartPoint;
  Timer? _restoreTimer;

  /// 主动恢复：详情页从小窗的位置展开，[_restoreTarget] 为页面中播放器的位置
  bool _expanding = false;

  /// 进入小窗：详情页收起到小窗的位置，下方露出实时页面
  bool _collapsing = false;

  /// 详情页与小窗之间的过渡，null 表示尚未开始
  _Container? _container;

  /// 过渡中代替详情页绘制的截图，视频画面以实时视频叠加
  ui.Image? _pageImage;

  /// 展开的背景，为恢复前的画面
  ui.Image? _backdrop;

  /// 展开的背景为页面层中实时显示的页面，页面层保持可见，详情页在其下方
  /// 不可见地完成绘制
  bool _liveBackdrop = false;

  /// 展开接近终点，页面层与详情页在截图下方提前显示
  bool _warm = false;
  final _childKey = GlobalKey();

  double get _progress => MiniPlayerMotion.curve.transform(_animation.value);

  /// 过渡的进度，0 为小窗，1 为整页；收起为展开的逆过程
  double get _containerProgress => _collapsing ? 1 - _progress : _progress;

  @override
  void initState() {
    super.initState();
    _animation =
        AnimationController(
          vsync: this,
          duration: MiniPlayerMotion.duration,
        )
        ..addListener(_onAnimationTick)
        ..addStatusListener((status) {
          if (status.isCompleted) {
            _onAnimationCompleted();
          }
        });
    _subscriptions = [
      _session.mode.listen(_onModeChanged),
      _session.restoring.listen(_onRestoringChanged),
      _session.restoreRect.listen(_onRestoreRectChanged),
    ];
  }

  @override
  void dispose() {
    for (final e in _subscriptions) {
      e.cancel();
    }
    _restoreTimer?.cancel();
    _animation.dispose();
    _pageImage?.dispose();
    _backdrop?.dispose();
    super.dispose();
  }

  /// 本帧仍在使用，绘制后再释放
  static void _disposeAfterFrame(ui.Image? image) {
    if (image != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => image.dispose());
    }
  }

  /// 结束或撤销展开、收起
  void _stopContainer() {
    _expanding = _collapsing = _liveBackdrop = _warm = false;
    _container = null;
    _disposeAfterFrame(_pageImage);
    _disposeAfterFrame(_backdrop);
    _pageImage = _backdrop = null;
  }

  void _hide() {
    if (_visible) {
      _retire();
    }
    _visible = _fadingOut = false;
    _from = _frozenTarget = _lastRect = _restoreTarget = null;
    _restoreTimer?.cancel();
    _stopContainer();
  }

  void _retire() {
    _retiring = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _retiring && !_visible) {
        setState(() => _retiring = false);
      }
    });
  }

  /// 展开接近终点时详情页在截图下方提前显示，缓存在交接前建立
  void _onAnimationTick() {
    if (_expanding &&
        !_warm &&
        _container != null &&
        _animation.value >= MiniPlayerMotion.warmAt) {
      _warm = true;
      _session.restoreStage = MiniRestoreStage.warm;
    }
  }

  /// 起点画面静止，上一帧的光栅化（截图、页面的首次绘制）完成后再开始过渡
  static Future<void> _holdStill() async {
    await WidgetsBinding.instance.endOfFrame;
    await WidgetsBinding.instance.endOfFrame;
  }

  void _animateFrom(Rect? from, {double? radius}) {
    _from = from;
    _fromRadius = radius ?? _lastRadius;
    _animation.forward(from: 0);
  }

  void _onAnimationCompleted() {
    if (!mounted || !_visible) {
      return;
    }
    if (_restoreTarget != null) {
      _finishRestoreIfReady();
      return;
    }
    setState(() {
      _from = null;
      _fromRadius = _radius;
      // 收起结束，交给小窗
      _stopContainer();
      if (_frozenTarget case final target?) {
        _frozenTarget = null;
        // 过渡期间布局发生变化时平滑移到新的位置
        final mediaQuery = MediaQuery.of(context);
        if (_miniRect(mediaQuery.size, mediaQuery.viewPadding) != target) {
          _animateFrom(target);
        }
      }
    });
  }

  /// 恢复动画结束且详情页已接管播放器后结束：展开时换回实时页面，
  /// 小窗飞回时淡出小窗
  void _finishRestoreIfReady() {
    if (!mounted ||
        !_visible ||
        _fadingOut ||
        _session.isActive ||
        (_restoreTarget != null &&
            (_expanding ? !_animation.isCompleted : _animation.isAnimating))) {
      return;
    }
    _restoreTimer?.cancel();
    if (_expanding) {
      setState(_hide);
      _session.finishRestore();
    } else {
      setState(() => _fadingOut = true);
    }
  }

  void _onFadeOutEnd() {
    if (!mounted || !_fadingOut) {
      return;
    }
    setState(_hide);
    _session.finishRestore();
  }

  void _onModeChanged(MiniPlayerMode mode) {
    if (!mounted) return;
    if (mode != .none) {
      if (!_visible || _fadingOut) {
        final mediaQuery = MediaQuery.of(context);
        setState(() {
          _hide();
          _visible = true;
          _placement = null;
          final mini = _frozenTarget = _miniRect(
            mediaQuery.size,
            mediaQuery.viewPadding,
          );
          final snapshot = _session.takeEnterSnapshot();
          final ready = _session.takeEnterReady();
          final player = _session.enterRect;
          if (snapshot != null && player != null && !player.isEmpty) {
            _beginCollapse(snapshot, mini, player, ready);
          } else {
            snapshot?.dispose();
            _animateFrom(player, radius: 0);
          }
        });
      }
    } else if (!_session.restoring.value) {
      setState(_hide);
    } else if (_restoreTarget != null) {
      _finishRestoreIfReady();
    } else {
      // 详情页未能提供播放器位置时直接结束
      _restoreTimer?.cancel();
      _restoreTimer = Timer(
        const Duration(seconds: 1),
        _finishRestoreIfReady,
      );
    }
  }

  void _onRestoringChanged(bool restoring) {
    if (!mounted || !_visible || _fadingOut) return;
    setState(() {
      if (restoring) {
        _beginRestore();
      } else if (_session.isActive) {
        // 恢复被取消，回到小窗位置
        _stopContainer();
        _restoreTarget = null;
        _animateFrom(_lastRect);
      } else {
        _hide();
      }
    });
  }

  /// 恢复开始时小窗停在原处，等详情页给出播放器位置后开始过渡；展开时
  /// 截取当前画面（路由变化前的最后一帧，详情页不在其中）作为背景，当前
  /// 页面含 platform view 时以实时页面为背景
  void _beginRestore() {
    if (_collapsing) {
      // 收起尚未结束时小窗停在收起的终点
      _stopContainer();
      _lastRect ??= _frozenTarget;
    }
    _animation.stop();
    _from = _lastRect;
    _fromRadius = _lastRadius;
    _animation.value = 0;
    _expanding = _session.expandRestore;
    _liveBackdrop = _expanding && _session.liveBackdrop;
    if (_expanding && _session.snapshotRestore) {
      _backdrop = _capture();
    }
  }

  void _onRestoreRectChanged(Rect? rect) {
    if (!mounted ||
        rect == null ||
        !_visible ||
        _fadingOut ||
        !_session.restoring.value) {
      return;
    }
    _restoreTimer?.cancel();
    if (_expanding) {
      _restoreTarget = rect;
      _beginExpand(rect);
      return;
    }
    setState(() {
      _restoreTarget = rect;
      _frozenTarget = null;
      _animateFrom(_lastRect);
    });
  }

  bool _awaitsExpand(Rect player) =>
      mounted &&
      _expanding &&
      _container == null &&
      identical(_restoreTarget, player);

  /// 以页面截图代替页面展开：详情页不上屏地绘制一帧，截图光栅化完成后
  /// 不再绘制；以起点画面静止后开始过渡，截图与页面的首次绘制都不落在
  /// 动画中
  Future<void> _beginExpand(Rect player) async {
    _session.restoreStage = MiniRestoreStage.capture;
    await WidgetsBinding.instance.endOfFrame;
    if (!_awaitsExpand(player)) {
      return;
    }
    final image = await _session.captureRestorePage();
    if (!_awaitsExpand(player)) {
      image?.dispose();
      return;
    }
    if (image == null) {
      // 截图失败时直接换为页面
      _warm = true;
      _session.restoreStage = MiniRestoreStage.warm;
      _animation.value = 1;
      return;
    }
    _session.restoreStage = MiniRestoreStage.motion;
    final container = _containerFor(_lastRect ?? player, player);
    setState(() {
      _pageImage = image;
      _container = container;
    });
    await _holdStill();
    if (mounted && identical(_container, container)) {
      _animation.forward(from: 0);
    }
  }

  /// 以详情页截图收起，页面在其下照常离开或被覆盖；系统栏等的变化完成后
  /// 以起点画面静止，再按变化后的小窗位置开始过渡
  void _beginCollapse(
    ui.Image snapshot,
    Rect mini,
    Rect player,
    Future<void>? ready,
  ) {
    _collapsing = true;
    _pageImage = snapshot;
    final container = _container = _containerFor(mini, player);
    _animation.value = 0;
    _startCollapse(container, ready);
  }

  Future<void> _startCollapse(_Container container, Future<void>? ready) async {
    if (ready != null) {
      try {
        await ready.timeout(MiniPlayerMotion.revealTimeout);
      } catch (_) {}
    }
    await _holdStill();
    if (!mounted || !identical(_container, container)) {
      return;
    }
    if (ready != null) {
      final mediaQuery = MediaQuery.of(context);
      final mini = _miniRect(mediaQuery.size, mediaQuery.viewPadding);
      if (mini != container.mini) {
        setState(() {
          _frozenTarget = mini;
          _container = _containerFor(mini, container.player);
        });
      }
    }
    _animation.forward(from: 0);
  }

  /// 小窗所在层（含所有页面）当前的画面
  ui.Image? _capture() {
    final boundary = _childKey.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary) {
      return null;
    }
    try {
      return boundary.toImageSync(
        pixelRatio: MediaQuery.devicePixelRatioOf(context),
      );
    } catch (_) {
      return null;
    }
  }

  /// 起点时页面整体缩放，页面中的视频画面与小窗中的重合；播放器不能完全
  /// 覆盖小窗时，记下小窗中播放器以外的部分（页面坐标）作为黑边遮罩
  _Container _containerFor(Rect mini, Rect player) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final miniVideo = _videoRect(mini, dpr);
    final pageVideo = _videoRect(player, dpr);
    // 保持比例的 fit 两者宽高比相同，拉伸时退化为整体 contain
    final scale = min(
      miniVideo.width / pageVideo.width,
      miniVideo.height / pageVideo.height,
    );
    final origin = miniVideo.center - pageVideo.center * scale;
    // 留出半个像素的舍入误差
    final covered = _mapRect(player, scale, origin).inflate(0.5);
    return (
      mini: mini,
      player: player,
      scale: scale,
      origin: origin,
      mask: covered.contains(mini.topLeft) && covered.contains(mini.bottomRight)
          ? null
          : Path.combine(
              PathOperation.difference,
              Path()..addRect(
                _mapRect(mini.shift(-origin), 1 / scale, Offset.zero),
              ),
              Path()..addRect(player),
            ),
    );
  }

  /// 视频画面在 [box] 中的位置，对应播放器与小窗中居中的 `FittedBox`：
  /// 按画面实际宽高比与 fit 计算，超出 [box] 的部分（如裁剪）一并计入
  static Rect _videoRect(Rect box, double devicePixelRatio) {
    final player = PlPlayerController.instance;
    final video = player?.videoController?.rect.value;
    if (player == null || video == null || video.isEmpty || box.isEmpty) {
      return box;
    }
    final fit = player.videoFit.value;
    final size =
        Size(
          fit.aspectRatio == null
              ? video.width
              : video.height * fit.aspectRatio!,
          video.height,
        ) /
        devicePixelRatio;
    final sizes = applyBoxFit(fit.boxFit, size, box.size);
    return Rect.fromCenter(
      center: box.center,
      width: size.width * sizes.destination.width / sizes.source.width,
      height: size.height * sizes.destination.height / sizes.source.height,
    );
  }

  static Rect _mapRect(Rect rect, double scale, Offset origin) =>
      Rect.fromLTWH(
        origin.dx + rect.left * scale,
        origin.dy + rect.top * scale,
        rect.width * scale,
        rect.height * scale,
      );

  /// 过渡在进度 [t]（0 为小窗，1 为整页）时的画面：页面截图等比缩放，
  /// 外框从小窗扩展到整个屏幕；起点时小窗黑边处的页面内容以随页面移动的
  /// 黑色遮罩盖住，前段淡去
  _ContainerFrame _frameOf(_Container container, Size size, double t) {
    final maskOpacity = clampDouble(1 - t / _maskFadeEnd, 0, 1);
    return (
      frame: RRect.fromRectAndRadius(
        Rect.lerp(container.mini, Offset.zero & size, t)!,
        Radius.circular(ui.lerpDouble(_radius, 0, t)!),
      ),
      scale: ui.lerpDouble(container.scale, 1, t)!,
      origin: container.origin * (1 - t),
      mask: maskOpacity == 0 ? null : container.mask,
      maskOpacity: maskOpacity,
      t: t,
    );
  }

  /// 页面层的结构保持不变，避免 Navigator 被重新挂载；过渡中的详情页
  /// 由截图与实时视频绘制，展开期间页面层不上屏（接近终点时在背景截图
  /// 下方提前显示），收起期间下方为实时页面
  Widget _buildPage(BuildContext context, Widget child) {
    final container = _container;
    final frame = container == null
        ? null
        : _frameOf(
            container,
            MediaQuery.sizeOf(context),
            _containerProgress,
          );
    final surface = ColorScheme.of(context).surface;
    final snapshotBackdrop = _expanding && !_liveBackdrop;
    final hidePage = snapshotBackdrop && !_warm;
    return Stack(
      fit: StackFit.expand,
      children: [
        CustomPaint(
          // 收起的详情页不再绘制，下方页面转场未覆盖的部分
          painter: _collapsing ? _FillPainter(surface) : null,
          foregroundPainter: _expanding || _collapsing
              ? _ContainerPainter(
                  backdrop: _backdrop,
                  backdropColor: snapshotBackdrop ? surface : null,
                  page: _pageImage,
                  frame: frame,
                )
              : null,
          child: IgnorePointer(
            ignoring: _expanding || _collapsing,
            child: ClipRect(
              clipper: hidePage ? const _EmptyClipper() : null,
              clipBehavior: hidePage ? Clip.hardEdge : Clip.none,
              child: child,
            ),
          ),
        ),
        if (frame != null) _buildContainerVideo(container!, frame),
      ],
    );
  }

  /// 过渡中播放器位置的实时视频：按详情页播放器的原始尺寸以同样的
  /// `FittedBox` 布局，再与截图一同缩放，各种 fit 下都与截图一致
  ///
  /// 底边让出进度条，截图中的进度条不被盖住
  Widget _buildContainerVideo(_Container container, _ContainerFrame frame) =>
      IgnorePointer(
        child: ClipRRect(
          clipper: _RRectClipper(frame.frame),
          child: Transform(
            transform: Matrix4.diagonal3Values(frame.scale, frame.scale, 1)
              ..setTranslationRaw(frame.origin.dx, frame.origin.dy, 0),
            child: Stack(
              children: [
                Positioned.fromRect(
                  rect: container.player,
                  child: const ClipRect(
                    clipper: _BottomInsetClipper(_progressBarInset),
                    child: ColoredBox(
                      color: Colors.black,
                      child: _MiniVideo(),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

  ({double left, double top, double right, double bottom}) _bounds(
    Size size,
    EdgeInsets padding,
  ) => (
    left: padding.left + _margin,
    top: padding.top + _margin,
    right: size.width - padding.right - _margin,
    bottom: size.height - padding.bottom - _margin,
  );

  double _minWidth(Size size, EdgeInsets padding) =>
      min(430.0, max(240.0, size.width - padding.horizontal - 48));

  double _maxWidth(Size size, EdgeInsets padding) {
    final availableWidth = max(240.0, size.width - padding.horizontal - 48);
    final availableHeight = max(160.0, size.height - padding.vertical - 48);
    return max(
      _minWidth(size, padding),
      min(
        760.0,
        min(
          size.width * 0.56,
          min(availableWidth, availableHeight * Style.aspectRatio16x9),
        ),
      ),
    );
  }

  Rect _clampRect(Rect rect, Size size, EdgeInsets padding) {
    final width = clampDouble(
      rect.width,
      _minWidth(size, padding),
      _maxWidth(size, padding),
    );
    final height = width / Style.aspectRatio16x9;
    final bounds = _bounds(size, padding);
    return Rect.fromLTWH(
      clampDouble(
        rect.left,
        bounds.left,
        max(bounds.left, bounds.right - width),
      ),
      clampDouble(
        rect.top,
        bounds.top,
        max(bounds.top, bounds.bottom - height),
      ),
      width,
      height,
    );
  }

  Rect _miniRect(Size size, EdgeInsets padding) {
    if (_placement case final placement?) {
      return _clampRect(placement, size, padding);
    }
    final width = _preferredWidth ?? size.width * 0.36;
    final bounds = _bounds(size, padding);
    return _clampRect(
      Rect.fromLTWH(
        bounds.right - width - 8,
        bounds.bottom - width / Style.aspectRatio16x9 - 8,
        width,
        width / Style.aspectRatio16x9,
      ),
      size,
      padding,
    );
  }

  ({bool left, bool right, bool top, bool bottom}) _edgeState(
    Rect rect,
    Size size,
    EdgeInsets padding,
  ) {
    final bounds = _bounds(size, padding);
    return (
      left: rect.left - bounds.left <= _edgeGestureDistance,
      right: bounds.right - rect.right <= _edgeGestureDistance,
      top: rect.top - bounds.top <= _edgeGestureDistance,
      bottom: bounds.bottom - rect.bottom <= _edgeGestureDistance,
    );
  }

  void _onGestureStart(DragStartDetails details) {
    _animation.stop();
    _gestureStartPoint = details.globalPosition;
    _gestureStartRect = _lastRect;
  }

  /// 手势直接摆放小窗，结束未完成的过渡
  void _placeAt(Rect placement) {
    _from = _frozenTarget = null;
    _fromRadius = _radius;
    _animation.value = 1;
    _placement = placement;
  }

  void _onMoveUpdate(DragUpdateDetails details, Size size, EdgeInsets padding) {
    if (_gestureStartRect case final start?) {
      setState(
        () => _placeAt(
          _clampRect(
            start.shift(details.globalPosition - _gestureStartPoint!),
            size,
            padding,
          ),
        ),
      );
    }
  }

  void _onMoveEnd(DragEndDetails details, Size size, EdgeInsets padding) {
    final start = _gestureStartRect;
    _gestureStartRect = _gestureStartPoint = null;
    final rect = _lastRect;
    if (start == null || rect == null) {
      return;
    }
    final edge = _edgeState(start, size, padding);
    final velocity = details.velocity.pixelsPerSecond;
    final dx = velocity.dx;
    final dy = velocity.dy;
    final horizontal = dx.abs() >= dy.abs();
    if ((horizontal && edge.left && dx < -_flingVelocity) ||
        (horizontal && edge.right && dx > _flingVelocity) ||
        (!horizontal && edge.top && dy < -_flingVelocity) ||
        (!horizontal && edge.bottom && dy > _flingVelocity)) {
      _session.close();
      return;
    }
    if (dy.abs() > dx.abs() * _restoreVerticalRatio &&
        ((edge.bottom && dy < -_restoreVelocity) ||
            (edge.top && dy > _restoreVelocity))) {
      _session.restore();
      return;
    }
    if (max(dx.abs(), dy.abs()) < _snapVelocity) {
      return;
    }
    final bounds = _bounds(size, padding);
    setState(() {
      _placement = _clampRect(
        horizontal
            ? Rect.fromLTWH(
                dx < 0 ? bounds.left : bounds.right - rect.width,
                rect.top,
                rect.width,
                rect.height,
              )
            : Rect.fromLTWH(
                rect.left,
                dy < 0 ? bounds.top : bounds.bottom - rect.height,
                rect.width,
                rect.height,
              ),
        size,
        padding,
      );
      _animateFrom(rect);
    });
  }

  void _onResizeUpdate(
    DragUpdateDetails details,
    Size size,
    EdgeInsets padding,
  ) {
    final start = _gestureStartRect;
    if (start == null) {
      return;
    }
    final delta = details.globalPosition - _gestureStartPoint!;
    final width = clampDouble(
      start.width - delta.dx - delta.dy * Style.aspectRatio16x9,
      _minWidth(size, padding),
      _maxWidth(size, padding),
    );
    setState(
      () => _placeAt(
        _clampRect(
          Rect.fromLTRB(
            start.right - width,
            start.bottom - width / Style.aspectRatio16x9,
            start.right,
            start.bottom,
          ),
          size,
          padding,
        ),
      ),
    );
  }

  void _onResizeEnd(DragEndDetails details) {
    _gestureStartRect = _gestureStartPoint = null;
    _preferredWidth = _placement?.width ?? _preferredWidth;
  }

  @override
  Widget build(BuildContext context) {
    final page = AnimatedBuilder(
      animation: _animation,
      builder: (context, child) => _buildPage(context, child!),
      child: RepaintBoundary(
        key: _childKey,
        child: MiniPlayerHostLayer(child: widget.child),
      ),
    );
    if (!_visible && !_retiring) {
      return Stack(fit: StackFit.expand, children: [page]);
    }
    final mediaQuery = MediaQuery.of(context);
    final size = mediaQuery.size;
    final padding = mediaQuery.viewPadding;
    final restoring = _restoreTarget != null;
    final target = _restoreTarget ?? _frozenTarget ?? _miniRect(size, padding);
    final handedOver = _container != null;
    final targetRadius = restoring ? 0.0 : _radius;
    return Stack(
      fit: StackFit.expand,
      children: [
        page,
        AnimatedBuilder(
          animation: _animation,
          builder: (context, child) {
            // 交给过渡中的详情页或已隐藏时保持挂载但不显示，过渡的起点、
            // 终点不重新构建小窗
            final offstage = handedOver || !_visible;
            final Rect rect;
            final double radius;
            if (offstage) {
              rect = _lastRect ?? target;
              radius = _lastRadius;
            } else {
              final t = _progress;
              final from = _from;
              rect = _lastRect = from == null
                  ? target
                  : Rect.lerp(from, target, t)!;
              radius = _lastRadius = from == null
                  ? targetRadius
                  : ui.lerpDouble(_fromRadius, targetRadius, t)!;
            }
            final borderRadius = BorderRadius.all(Radius.circular(radius));
            return Positioned.fromRect(
              rect: rect,
              child: Offstage(
                offstage: offstage,
                child: AnimatedOpacity(
                  opacity: _fadingOut ? 0 : 1,
                  duration: _fadeOutDuration,
                  onEnd: _onFadeOutEnd,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black,
                      borderRadius: borderRadius,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(
                            alpha: 0.28 * radius / _radius,
                          ),
                          blurRadius: 24,
                          offset: const Offset(0, 12),
                        ),
                      ],
                    ),
                    child: ClipRRect(borderRadius: borderRadius, child: child),
                  ),
                ),
              ),
            );
          },
          child: IgnorePointer(
            ignoring: restoring || _expanding || _fadingOut,
            child: _MiniPlayerSurface(
              restoring: restoring || _expanding,
              onMoveStart: _onGestureStart,
              onMoveUpdate: (details) => _onMoveUpdate(details, size, padding),
              onMoveEnd: (details) => _onMoveEnd(details, size, padding),
              onResizeStart: _onGestureStart,
              onResizeUpdate: (details) =>
                  _onResizeUpdate(details, size, padding),
              onResizeEnd: _onResizeEnd,
            ),
          ),
        ),
      ],
    );
  }
}

/// [mask] 为页面坐标中小窗黑边处的遮罩，开始时计算一次
typedef _Container = ({
  Rect mini,
  Rect player,
  double scale,
  Offset origin,
  Path? mask,
});

typedef _ContainerFrame = ({
  RRect frame,
  double scale,
  Offset origin,
  Path? mask,
  double maskOpacity,
  double t,
});

/// 过渡的背景（随进度轻微变暗）、外框阴影、缩放的页面截图与黑边遮罩；
/// 只绘制图片与简单图形，不重新光栅化页面
class _ContainerPainter extends CustomPainter {
  _ContainerPainter({
    required this.backdrop,
    required this.backdropColor,
    required this.page,
    required this.frame,
  });

  final ui.Image? backdrop;

  /// 背景色，垫在背景截图下方：截图中页面层未铺满的部分（如覆盖页仍在
  /// 入场）是透明的，不能露出；null 表示露出下方的实时画面
  final Color? backdropColor;
  final ui.Image? page;

  /// null 表示尚未开始
  final _ContainerFrame? frame;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    if (backdropColor case final color?) {
      canvas.drawRect(rect, Paint()..color = color);
    }
    if (backdrop case final backdrop?) {
      paintImage(
        canvas: canvas,
        rect: rect,
        image: backdrop,
        fit: BoxFit.fill,
        filterQuality: FilterQuality.low,
      );
    }
    final frame = this.frame;
    if (frame == null) {
      return;
    }
    final t = frame.t;
    canvas.drawRect(
      rect,
      Paint()
        ..color = Colors.black.withValues(
          alpha: _AppMiniPlayerOverlayState._backdropDim * t,
        ),
    );
    // 与小窗相同的阴影，随圆角一同消失
    final shadow = BoxShadow(
      color: Colors.black.withValues(alpha: 0.28 * (1 - t)),
      blurRadius: 24,
      offset: const Offset(0, 12),
    );
    canvas
      ..drawRRect(frame.frame.shift(shadow.offset), shadow.toPaint())
      ..save()
      ..clipRRect(frame.frame)
      // 截图与遮罩随页面缩放
      ..translate(frame.origin.dx, frame.origin.dy)
      ..scale(frame.scale);
    if (page case final page?) {
      canvas.drawImageRect(
        page,
        Offset.zero & Size(page.width.toDouble(), page.height.toDouble()),
        rect,
        Paint()..filterQuality = FilterQuality.medium,
      );
    }
    if (frame.mask case final mask?) {
      canvas.drawPath(
        mask,
        Paint()..color = Colors.black.withValues(alpha: frame.maskOpacity),
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ContainerPainter oldDelegate) => true;
}

class _FillPainter extends CustomPainter {
  const _FillPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) =>
      canvas.drawRect(Offset.zero & size, Paint()..color = color);

  @override
  bool shouldRepaint(_FillPainter oldDelegate) => oldDelegate.color != color;
}

class _BottomInsetClipper extends CustomClipper<Rect> {
  const _BottomInsetClipper(this.inset);

  final double inset;

  @override
  Rect getClip(Size size) =>
      Rect.fromLTRB(0, 0, size.width, size.height - inset);

  @override
  bool shouldReclip(_BottomInsetClipper oldClipper) =>
      oldClipper.inset != inset;
}

class _EmptyClipper extends CustomClipper<Rect> {
  const _EmptyClipper();

  @override
  Rect getClip(Size size) => Rect.zero;

  @override
  bool shouldReclip(_EmptyClipper oldClipper) => false;
}

class _RRectClipper extends CustomClipper<RRect> {
  const _RRectClipper(this.rrect);

  final RRect rrect;

  @override
  RRect getClip(Size size) => rrect;

  @override
  bool shouldReclip(_RRectClipper oldClipper) => oldClipper.rrect != rrect;
}

class _MiniPlayerSurface extends StatefulWidget {
  const _MiniPlayerSurface({
    required this.restoring,
    required this.onMoveStart,
    required this.onMoveUpdate,
    required this.onMoveEnd,
    required this.onResizeStart,
    required this.onResizeUpdate,
    required this.onResizeEnd,
  });

  final bool restoring;
  final GestureDragStartCallback onMoveStart;
  final GestureDragUpdateCallback onMoveUpdate;
  final GestureDragEndCallback onMoveEnd;
  final GestureDragStartCallback onResizeStart;
  final GestureDragUpdateCallback onResizeUpdate;
  final GestureDragEndCallback onResizeEnd;

  @override
  State<_MiniPlayerSurface> createState() => _MiniPlayerSurfaceState();
}

class _MiniPlayerSurfaceState extends State<_MiniPlayerSurface> {
  static const _controlsHideDelay = Duration(seconds: 4);

  Timer? _hideTimer;
  bool _controlsVisible = false;

  @override
  void didUpdateWidget(_MiniPlayerSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.restoring) {
      _hideTimer?.cancel();
      _controlsVisible = false;
    }
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    super.dispose();
  }

  void _setControlsVisible(bool visible) {
    if (mounted && _controlsVisible != visible) {
      setState(() => _controlsVisible = visible);
    }
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    if (_controlsVisible) {
      _hideTimer = Timer(_controlsHideDelay, () => _setControlsVisible(false));
    }
  }

  void _showControls() {
    _setControlsVisible(true);
    _scheduleHide();
  }

  void _togglePlayback() {
    if (PlPlayerController.instance case final player?) {
      if (player.playerStatus.isPlaying) {
        miniPlayerSession.pause();
      } else {
        miniPlayerSession.play();
      }
    }
    _scheduleHide();
  }

  Widget _buildLoading(ColorScheme colorScheme) => SizedBox.square(
    dimension: 34,
    child: CircularProgressIndicator(
      strokeWidth: 3,
      color: colorScheme.primary,
    ),
  );

  Widget _buildControls(ColorScheme colorScheme) {
    final player = PlPlayerController.instance;
    return IgnorePointer(
      ignoring: !_controlsVisible,
      child: AnimatedOpacity(
        opacity: _controlsVisible ? 1 : 0,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOutCubic,
        child: Stack(
          fit: StackFit.expand,
          children: [
            IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.42),
                      Colors.transparent,
                      Colors.black.withValues(alpha: 0.72),
                    ],
                    stops: const [0, 0.42, 1],
                  ),
                ),
              ),
            ),
            Positioned(
              top: 6,
              left: 6,
              child: Tooltip(
                message: '拖动调整大小',
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanStart: (details) {
                    _hideTimer?.cancel();
                    widget.onResizeStart(details);
                  },
                  onPanUpdate: widget.onResizeUpdate,
                  onPanEnd: (details) {
                    widget.onResizeEnd(details);
                    _scheduleHide();
                  },
                  child: const _MiniButtonBox(icon: Icons.open_in_full),
                ),
              ),
            ),
            Positioned(
              top: 6,
              right: 6,
              child: Row(
                spacing: 6,
                children: [
                  _MiniIconButton(
                    tooltip: '返回详情',
                    icon: Icons.fullscreen,
                    onPressed: miniPlayerSession.restore,
                  ),
                  _MiniIconButton(
                    tooltip: '关闭小窗',
                    icon: Icons.close,
                    onPressed: miniPlayerSession.close,
                  ),
                ],
              ),
            ),
            Center(
              child: Obx(() {
                if (miniPlayerSession.isLoading) {
                  return _buildLoading(colorScheme);
                }
                final videoPlayer = player?.videoPlayerController;
                return StreamBuilder<bool>(
                  stream: videoPlayer?.stream.playing,
                  initialData: videoPlayer?.state.playing ?? false,
                  builder: (context, snapshot) {
                    final isPlaying = snapshot.data ?? false;
                    return _MiniIconButton(
                      tooltip: isPlaying ? '暂停' : '播放',
                      icon: isPlaying ? Icons.pause : Icons.play_arrow,
                      size: 40,
                      iconSize: 26,
                      onPressed: _togglePlayback,
                    );
                  },
                );
              }),
            ),
            Positioned(
              left: 12,
              right: 12,
              bottom: 10,
              child: IgnorePointer(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Obx(() {
                            final title = miniPlayerSession.title;
                            return Text(
                              title.isEmpty ? '正在播放' : title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            );
                          }),
                        ),
                        ShutdownPanel(
                          buildCountdownText: (text) {
                            if (text == null) {
                              return const SizedBox.shrink();
                            }
                            return Padding(
                              padding: const EdgeInsets.only(left: 8),
                              child: Row(
                                spacing: 2,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(
                                    Icons.schedule,
                                    size: 13,
                                    color: Colors.white,
                                  ),
                                  Text(
                                    shutdownTimerService.isWaiting
                                        ? '播完停止'
                                        : text,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    if (player != null)
                      Obx(() {
                        final total = player.duration.value;
                        final position = player.position.value
                            .clamp(0, total)
                            .toInt();
                        return Row(
                          children: [
                            Expanded(
                              child: ClipRRect(
                                borderRadius: const BorderRadius.all(
                                  Radius.circular(999),
                                ),
                                child: LinearProgressIndicator(
                                  minHeight: 3,
                                  value: total == 0 ? 0 : position / total,
                                  backgroundColor: Colors.white.withValues(
                                    alpha: 0.28,
                                  ),
                                  color: colorScheme.primary,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              DurationUtils.formatDuration(position),
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.88),
                                fontSize: 11,
                              ),
                            ),
                          ],
                        );
                      }),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.of(context);
    return Material(
      type: MaterialType.transparency,
      child: Stack(
        fit: StackFit.expand,
        children: [
          const _MiniVideo(),
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _togglePlayback,
              onLongPress: _showControls,
              onPanStart: (details) {
                _hideTimer?.cancel();
                widget.onMoveStart(details);
              },
              onPanUpdate: widget.onMoveUpdate,
              onPanEnd: (details) {
                widget.onMoveEnd(details);
                _scheduleHide();
              },
            ),
          ),
          if (!_controlsVisible)
            IgnorePointer(
              child: Center(
                child: Obx(
                  () => miniPlayerSession.isLoading
                      ? _buildLoading(colorScheme)
                      : const SizedBox.shrink(),
                ),
              ),
            ),
          _buildControls(colorScheme),
        ],
      ),
    );
  }
}

/// 小窗中的视频画面，播放器尚未就绪时为封面
class _MiniVideo extends StatelessWidget {
  const _MiniVideo();

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      miniPlayerSession.mode.value;
      final player = PlPlayerController.instance;
      final videoController = player?.videoController;
      if (player != null && videoController != null) {
        final videoFit = player.videoFit.value;
        return FittedBox(
          fit: videoFit.boxFit,
          child: SimpleVideo(
            controller: videoController,
            aspectRatio: videoFit.aspectRatio,
          ),
        );
      }
      final cover = miniPlayerSession.cover;
      if (cover.isEmpty) {
        return const SizedBox.shrink();
      }
      return LayoutBuilder(
        builder: (context, constraints) => NetworkImgLayer(
          src: cover,
          width: constraints.maxWidth,
          height: constraints.maxHeight,
          quality: 60,
          borderRadius: BorderRadius.zero,
        ),
      );
    });
  }
}

class _MiniButtonBox extends StatelessWidget {
  const _MiniButtonBox({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.52),
        borderRadius: const BorderRadius.all(Radius.circular(6)),
      ),
      child: Icon(icon, size: 17, color: Colors.white),
    );
  }
}

class _MiniIconButton extends StatelessWidget {
  const _MiniIconButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.size = 32,
    this.iconSize = 20,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;
  final double size;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: IconButton.filledTonal(
        tooltip: tooltip,
        style: IconButton.styleFrom(
          padding: EdgeInsets.zero,
          backgroundColor: Colors.black.withValues(alpha: 0.52),
          foregroundColor: Colors.white,
          hoverColor: Colors.white.withValues(alpha: 0.12),
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(6)),
          ),
        ),
        iconSize: iconSize,
        onPressed: onPressed,
        icon: Icon(icon),
      ),
    );
  }
}
