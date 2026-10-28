import 'dart:async' show StreamSubscription, Timer;
import 'dart:math' show max, min;
import 'dart:ui' as ui show Image, lerpDouble;

import 'package:PiliPlus/common/style.dart';
import 'package:PiliPlus/common/widgets/image/network_img_layer.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/services/mini_player/mini_player_policy.dart';
import 'package:PiliPlus/services/mini_player/mini_player_session.dart';
import 'package:PiliPlus/services/shutdown_timer_service.dart';
import 'package:PiliPlus/utils/duration_utils.dart';
import 'package:flutter/foundation.dart' show clampDouble;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:get/get.dart';
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

  final _session = miniPlayerSession;

  /// 唯一的动画驱动：位置、大小、圆角与截图淡出共用同一进度
  late final AnimationController _animation;
  late final List<StreamSubscription> _subscriptions;

  bool _visible = false;

  /// 恢复完成后淡出小窗
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

  /// 过渡期间淡出的截图：缩小时为详情页（并留出播放器的位置），
  /// 恢复时为恢复前的画面，详情页在其下完成首次构建
  ui.Image? _snapshot;
  Rect? _snapshotHole;
  final _childKey = GlobalKey();

  double get _progress => MiniPlayerMotion.curve.transform(_animation.value);

  @override
  void initState() {
    super.initState();
    _animation =
        AnimationController(
          vsync: this,
          duration: MiniPlayerMotion.duration,
        )..addStatusListener((status) {
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
    _snapshot?.dispose();
    super.dispose();
  }

  void _releaseSnapshot() {
    final snapshot = _snapshot;
    _snapshot = _snapshotHole = null;
    if (snapshot != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => snapshot.dispose());
    }
  }

  void _hide() {
    _visible = _fadingOut = false;
    _from = _frozenTarget = _lastRect = _restoreTarget = null;
    _restoreTimer?.cancel();
    _releaseSnapshot();
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
      _releaseSnapshot();
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

  /// 恢复动画结束且详情页已接管播放器后淡出小窗
  void _finishRestoreIfReady() {
    if (!mounted ||
        !_visible ||
        _fadingOut ||
        _session.isActive ||
        (_restoreTarget != null && _animation.isAnimating)) {
      return;
    }
    _restoreTimer?.cancel();
    setState(() => _fadingOut = true);
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
          _snapshot = _session.takeEnterSnapshot();
          final enterRect = _session.enterRect;
          _snapshotHole = enterRect;
          _frozenTarget = _miniRect(mediaQuery.size, mediaQuery.viewPadding);
          _animateFrom(enterRect, radius: 0);
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
        _captureScreen();
      } else if (_session.isActive) {
        // 恢复被取消，回到小窗位置
        _releaseSnapshot();
        _restoreTarget = null;
        _animateFrom(_lastRect);
      } else {
        _hide();
      }
    });
  }

  /// 恢复开始时截取当前画面（路由变化前的最后一帧），
  /// 小窗停在原处，等详情页给出目标位置后与截图淡出一同开始
  void _captureScreen() {
    _releaseSnapshot();
    _animation.stop();
    _from = _lastRect;
    _fromRadius = _lastRadius;
    _animation.value = 0;
    final boundary = _childKey.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary) {
      return;
    }
    try {
      _snapshot = boundary.toImageSync(
        pixelRatio: MediaQuery.devicePixelRatioOf(context),
      );
    } catch (_) {}
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
    setState(() {
      _restoreTarget = rect;
      _frozenTarget = null;
      _animateFrom(_lastRect);
    });
  }

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
    _releaseSnapshot();
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
    final child = RepaintBoundary(key: _childKey, child: widget.child);
    if (!_visible) {
      return child;
    }
    final mediaQuery = MediaQuery.of(context);
    final size = mediaQuery.size;
    final padding = mediaQuery.viewPadding;
    final restoring = _restoreTarget != null;
    final target = _restoreTarget ?? _frozenTarget ?? _miniRect(size, padding);
    final targetRadius = restoring ? 0.0 : _radius;
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        if (_snapshot case final snapshot?)
          IgnorePointer(
            child: AnimatedBuilder(
              animation: _animation,
              builder: (context, child) => Opacity(
                opacity: 1 - _progress,
                child: child,
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  RawImage(image: snapshot, fit: BoxFit.fill),
                  if (_snapshotHole case final hole?)
                    Positioned.fromRect(
                      rect: hole,
                      child: const ColoredBox(color: Colors.black),
                    ),
                ],
              ),
            ),
          ),
        AnimatedBuilder(
          animation: _animation,
          builder: (context, child) {
            final t = _progress;
            final from = _from;
            final rect = _lastRect = from == null
                ? target
                : Rect.lerp(from, target, t)!;
            final radius = _lastRadius = from == null
                ? targetRadius
                : ui.lerpDouble(_fromRadius, targetRadius, t)!;
            final borderRadius = BorderRadius.all(Radius.circular(radius));
            return Positioned.fromRect(
              rect: rect,
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
            );
          },
          child: IgnorePointer(
            ignoring: restoring || _fadingOut,
            child: _MiniPlayerSurface(
              restoring: restoring,
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

  Widget _buildVideo() {
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
                if (miniPlayerSession.loading.value) {
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
          _buildVideo(),
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
                  () => miniPlayerSession.loading.value
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
