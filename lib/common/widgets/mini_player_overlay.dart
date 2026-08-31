import 'dart:async' show Timer, unawaited;
import 'dart:math' show max, min;
import 'dart:ui';

import 'package:PiliPlus/common/style.dart';
import 'package:PiliPlus/common/widgets/image/network_img_layer.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/services/mini_player_service.dart';
import 'package:PiliPlus/utils/duration_utils.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:media_kit_video/media_kit_video.dart';

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
  static const double _edgeGestureDistance = 72;
  static const double _flingVelocity = 650;
  static const double _restoreVelocity = 420;
  static const double _snapVelocity = 420;
  static const double _restoreVerticalRatio = 0.75;

  final MiniPlayerService _service = MiniPlayerService.ensureInitialized;
  late final AnimationController _controller;

  Rect? _beginRect;
  Rect? _targetRect;
  Rect? _lastPaintRect;
  Rect? _moveStartRect;
  Rect? _resizeStartRect;
  Offset? _moveStartPoint;
  Offset? _resizeStartPoint;
  bool _restoreAnimating = false;
  bool _moving = false;
  bool _resizing = false;
  String? _restoreAnimatingHeroTag;
  Timer? _restoreTargetTimer;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
    );
  }

  @override
  void dispose() {
    _restoreTargetTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  double _minMiniWidth(Size size, EdgeInsets padding) {
    final availableWidth = max(
      240.0,
      size.width - padding.left - padding.right - 48,
    );
    return min(430.0, availableWidth);
  }

  double _maxMiniWidth(Size size, EdgeInsets padding) {
    final availableWidth = max(
      240.0,
      size.width - padding.left - padding.right - 48,
    );
    final availableHeight = max(
      160.0,
      size.height - padding.top - padding.bottom - 48,
    );
    final maxByHeight = availableHeight * Style.aspectRatio16x9;
    return max(
      _minMiniWidth(size, padding),
      min(760.0, min(size.width * 0.56, min(availableWidth, maxByHeight))),
    );
  }

  Rect _defaultMiniRect(Size size, EdgeInsets padding) {
    final width = clampDouble(
      _service.preferredMiniPlayerWidth ?? size.width * 0.36,
      _minMiniWidth(size, padding),
      _maxMiniWidth(size, padding),
    );
    final height = width / Style.aspectRatio16x9;
    return Rect.fromLTWH(
      size.width - padding.right - width - 24,
      size.height - padding.bottom - height - 24,
      width,
      height,
    );
  }

  Rect _clampRect(Rect rect, Size size, EdgeInsets padding) {
    final width = clampDouble(
      rect.width,
      _minMiniWidth(size, padding),
      _maxMiniWidth(size, padding),
    );
    final height = width / Style.aspectRatio16x9;
    final leftLimit = padding.left + 16;
    final topLimit = padding.top + 16;
    final rightLimit = size.width - padding.right - 16;
    final bottomLimit = size.height - padding.bottom - 16;
    final maxLeft = max(leftLimit, rightLimit - width);
    final maxTop = max(topLimit, bottomLimit - height);
    return Rect.fromLTWH(
      clampDouble(rect.left, leftLimit, maxLeft),
      clampDouble(rect.top, topLimit, maxTop),
      width,
      height,
    );
  }

  ({bool left, bool right, bool top, bool bottom}) _edgeState(
    Rect rect,
    Size size,
    EdgeInsets padding,
  ) {
    final leftLimit = padding.left + 16;
    final topLimit = padding.top + 16;
    final rightLimit = size.width - padding.right - 16;
    final bottomLimit = size.height - padding.bottom - 16;
    return (
      left: rect.left - leftLimit <= _edgeGestureDistance,
      right: rightLimit - rect.right <= _edgeGestureDistance,
      top: rect.top - topLimit <= _edgeGestureDistance,
      bottom: bottomLimit - rect.bottom <= _edgeGestureDistance,
    );
  }

  bool _shouldCloseByFling(
    ({bool left, bool right, bool top, bool bottom}) edge,
    Velocity velocity,
  ) {
    final pixels = velocity.pixelsPerSecond;
    final dx = pixels.dx;
    final dy = pixels.dy;
    final absDx = dx.abs();
    final absDy = dy.abs();
    final horizontalIntent = absDx >= absDy;
    final verticalIntent = absDy > absDx;
    return (horizontalIntent && edge.left && dx < -_flingVelocity) ||
        (horizontalIntent && edge.right && dx > _flingVelocity) ||
        (verticalIntent && edge.top && dy < -_flingVelocity) ||
        (verticalIntent && edge.bottom && dy > _flingVelocity);
  }

  bool _shouldRestoreByFling(
    ({bool left, bool right, bool top, bool bottom}) edge,
    Velocity velocity,
  ) {
    final pixels = velocity.pixelsPerSecond;
    final dx = pixels.dx;
    final dy = pixels.dy;
    final absDx = dx.abs();
    final absDy = dy.abs();
    if (absDy <= absDx * _restoreVerticalRatio) {
      return false;
    }
    return (edge.bottom && dy < -_restoreVelocity) ||
        (edge.top && dy > _restoreVelocity);
  }

  Rect _snapRectForFling(
    Rect rect,
    Velocity velocity,
    Size size,
    EdgeInsets padding,
  ) {
    final pixels = velocity.pixelsPerSecond;
    final dx = pixels.dx;
    final dy = pixels.dy;
    final absDx = dx.abs();
    final absDy = dy.abs();
    if (max(absDx, absDy) < _snapVelocity) {
      return rect;
    }

    final leftLimit = padding.left + 16;
    final topLimit = padding.top + 16;
    final rightLimit = size.width - padding.right - 16;
    final bottomLimit = size.height - padding.bottom - 16;
    if (absDx >= absDy) {
      final left = dx < 0 ? leftLimit : rightLimit - rect.width;
      return _clampRect(
        Rect.fromLTWH(left, rect.top, rect.width, rect.height),
        size,
        padding,
      );
    }
    final top = dy < 0 ? topLimit : bottomLimit - rect.height;
    return _clampRect(
      Rect.fromLTWH(rect.left, top, rect.width, rect.height),
      size,
      padding,
    );
  }

  Rect _normalizeRestoreRect(Rect rect, Size size, EdgeInsets padding) {
    final fallbackHeight = size.width / Style.aspectRatio16x9;
    if (rect.isEmpty ||
        !rect.left.isFinite ||
        !rect.top.isFinite ||
        !rect.width.isFinite ||
        !rect.height.isFinite ||
        rect.width < 80 ||
        rect.height < 45) {
      return Rect.fromLTWH(
        0,
        padding.top,
        size.width,
        fallbackHeight,
      );
    }

    final width = clampDouble(rect.width, 80, size.width);
    final height = clampDouble(rect.height, 45, size.height - padding.top);
    final maxLeft = max(0.0, size.width - width);
    final maxTop = max(padding.top, size.height - padding.bottom - height);
    return Rect.fromLTWH(
      clampDouble(rect.left, 0, maxLeft),
      clampDouble(rect.top, padding.top, maxTop),
      width,
      height,
    );
  }

  void _snapTo(Rect rect) {
    if (_controller.isAnimating) {
      _controller.stop();
    }
    _restoreAnimating = false;
    _restoreAnimatingHeroTag = null;
    _controller.value = 1;
    _beginRect = rect;
    _targetRect = rect;
    _lastPaintRect = rect;
  }

  void _resetTransientState() {
    if (_controller.isAnimating) {
      _controller.stop();
    }
    _beginRect = null;
    _targetRect = null;
    _lastPaintRect = null;
    _moveStartPoint = null;
    _moveStartRect = null;
    _resizeStartPoint = null;
    _resizeStartRect = null;
    _moving = false;
    _resizing = false;
    _restoreAnimating = false;
    _restoreAnimatingHeroTag = null;
    _restoreTargetTimer?.cancel();
    _restoreTargetTimer = null;
  }

  void _runAnimation({
    required VoidCallback onCompleted,
    VoidCallback? onCanceled,
  }) {
    unawaited(
      _controller.forward(from: 0).orCancel.then((_) {
        if (mounted) {
          onCompleted();
        }
      }).catchError((_) {
        if (mounted) {
          onCanceled?.call();
        }
      }),
    );
  }

  void _ensureForwardAnimation(Rect target, MiniPlayerSnapshot snapshot) {
    if (_restoreAnimating || _service.restoring.value) {
      return;
    }
    if (_targetRect == target &&
        (_controller.isAnimating || _controller.value == 1)) {
      return;
    }
    _beginRect = _lastPaintRect ??
        (snapshot.sourceRect.isEmpty ? target : snapshot.sourceRect);
    _targetRect = target;
    unawaited(_service.minimizeCurrentRoute());
    _runAnimation(
      onCompleted: () {
        if (_service.isEntering && !_service.isRestoring) {
          unawaited(_service.finishEnterAnimation());
        }
      },
      onCanceled: () {
        if (_service.isEntering && !_service.isRestoring) {
          unawaited(_service.finishEnterAnimation());
        }
      },
    );
  }

  Future<void> _restore(Rect current) async {
    if (_service.isEntering || _restoreAnimating || !_service.beginRestore()) {
      return;
    }
    _beginRect = current;
    _targetRect = current;
    _lastPaintRect = current;
    if (mounted) {
      _service.restore();
      _restoreTargetTimer?.cancel();
      _restoreTargetTimer = Timer(const Duration(seconds: 3), () {
        if (!mounted ||
            !_service.isRestoring ||
            _service.restoreTarget.value != null) {
          return;
        }
        _service.cancelRestore(popRestoredRoute: true);
        _restoreAnimating = false;
        _restoreAnimatingHeroTag = null;
      });
    }
  }

  void _ensureRestoreAnimation(Rect target, String heroTag) {
    if (_restoreAnimating && _restoreAnimatingHeroTag == heroTag) {
      return;
    }
    _restoreAnimating = true;
    _restoreAnimatingHeroTag = heroTag;
    _restoreTargetTimer?.cancel();
    _restoreTargetTimer = null;
    _beginRect = _lastPaintRect ?? _service.placement.value ?? target;
    _targetRect = target;
    _runAnimation(
      onCompleted: () {
        if (_service.isRestoring) {
          _service.finishRestore(heroTag);
        }
        _restoreAnimating = false;
        _restoreAnimatingHeroTag = null;
      },
      onCanceled: () {
        if (_service.isRestoring) {
          _service.cancelRestore(popRestoredRoute: true);
        }
        _restoreAnimating = false;
        _restoreAnimatingHeroTag = null;
      },
    );
  }

  Widget _restoreRevealScrim() {
    return IgnorePointer(
      child: ColoredBox(
        color: Colors.black.withValues(
          alpha: clampDouble(
            1 - ((_controller.value - 0.62) / 0.38),
            0,
            1,
          ),
        ),
      ),
    );
  }

  void _startMove(DragStartDetails details, Rect current) {
    if (_service.isEntering || _service.isRestoring) {
      return;
    }
    _moving = true;
    _moveStartPoint = details.globalPosition;
    _moveStartRect = _lastPaintRect ?? current;
    _service.updatePlacement(_moveStartRect!);
    _snapTo(_moveStartRect!);
  }

  void _updateMove(
    DragUpdateDetails details,
    Size size,
    EdgeInsets padding,
  ) {
    final startPoint = _moveStartPoint;
    final startRect = _moveStartRect;
    if (!_moving || startPoint == null || startRect == null) {
      return;
    }
    final rect = _clampRect(
      startRect.shift(details.globalPosition - startPoint),
      size,
      padding,
    );
    _service.updatePlacement(rect);
    _snapTo(rect);
  }

  void _endMove(
    DragEndDetails details,
    Rect current,
    Size size,
    EdgeInsets padding,
  ) {
    final rect = _lastPaintRect ?? current;
    final startRect = _moveStartRect ?? rect;
    final startEdge = _edgeState(startRect, size, padding);
    _moving = false;
    _moveStartPoint = null;
    _moveStartRect = null;
    if (_shouldCloseByFling(startEdge, details.velocity)) {
      _service.close();
      return;
    }
    if (_shouldRestoreByFling(startEdge, details.velocity)) {
      _restore(rect);
      return;
    }
    final snapped = _snapRectForFling(rect, details.velocity, size, padding);
    if (snapped != rect) {
      _service.updatePlacement(snapped);
      _snapTo(snapped);
    }
  }

  void _startResize(DragStartDetails details, Rect current) {
    if (_service.isEntering || _service.isRestoring) {
      return;
    }
    _resizing = true;
    _resizeStartPoint = details.globalPosition;
    _resizeStartRect = _lastPaintRect ?? current;
    _service.updatePlacement(_resizeStartRect!);
    _snapTo(_resizeStartRect!);
  }

  void _updateResize(
    DragUpdateDetails details,
    Size size,
    EdgeInsets padding,
  ) {
    final startPoint = _resizeStartPoint;
    final startRect = _resizeStartRect;
    if (!_resizing || startPoint == null || startRect == null) {
      return;
    }
    final delta = details.globalPosition - startPoint;
    final width = startRect.width -
        delta.dx -
        delta.dy * Style.aspectRatio16x9;
    final clampedWidth = clampDouble(
      width,
      _minMiniWidth(size, padding),
      _maxMiniWidth(size, padding),
    );
    final height = clampedWidth / Style.aspectRatio16x9;
    final rect = _clampRect(
      Rect.fromLTRB(
        startRect.right - clampedWidth,
        startRect.bottom - height,
        startRect.right,
        startRect.bottom,
      ),
      size,
      padding,
    );
    _service.updatePlacement(rect);
    _snapTo(rect);
  }

  void _endResize(DragEndDetails details) {
    final rect = _lastPaintRect ?? _service.placement.value;
    if (rect != null) {
      _service.updatePreferredMiniPlayerWidth(rect.width);
    }
    _resizing = false;
    _resizeStartPoint = null;
    _resizeStartRect = null;
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        Obx(() {
          final snapshot = _service.snapshot.value;
          if (!_service.visible.value || snapshot == null) {
            _resetTransientState();
            return const SizedBox.shrink();
          }

          final mediaQuery = MediaQuery.of(context);
          final size = mediaQuery.size;
          final padding = mediaQuery.viewPadding;
          final miniTarget = _clampRect(
            _service.placement.value ?? _defaultMiniRect(size, padding),
            size,
            padding,
          );
          final restoreTarget = _service.restoreTarget.value;
          final restoreHeroTag = _service.restoringHeroTag;
          final isRestoreToPage = _service.restoring.value &&
              restoreTarget != null &&
              restoreHeroTag != null;
          final target = isRestoreToPage
              ? _normalizeRestoreRect(restoreTarget!, size, padding)
              : miniTarget;
          final hasManualPlacement =
              _service.placement.value != null && !_service.restoring.value;

          if (isRestoreToPage) {
            _ensureRestoreAnimation(target, restoreHeroTag!);
          } else if (!_service.restoring.value && !hasManualPlacement) {
            _ensureForwardAnimation(target, snapshot);
          }

          return AnimatedBuilder(
            animation: _controller,
            builder: (context, child) {
              final progress = Curves.easeOutCubic.transform(
                _controller.value,
              );
              final rect = _service.restoring.value && !isRestoreToPage
                  ? _lastPaintRect ?? target
                  : hasManualPlacement
                  ? target
                  : Rect.lerp(
                      _beginRect ?? target,
                      _targetRect ?? target,
                      progress,
                    )!;
              _lastPaintRect = rect;
              return Stack(
                fit: StackFit.expand,
                children: [
                  if (_service.restoring.value) _restoreRevealScrim(),
                  Positioned.fromRect(
                    rect: rect,
                    child: child!,
                  ),
                ],
              );
            },
            child: _MiniPlayerSurface(
              key: ValueKey(
                '${snapshot.heroTag}-${snapshot.cid}-'
                '${identityHashCode(snapshot.plPlayerController.videoController)}',
              ),
              service: _service,
              onMoveStart: (details) => _startMove(details, target),
              onMoveUpdate: (details) => _updateMove(details, size, padding),
              onMoveEnd: (details) => _endMove(
                details,
                target,
                size,
                padding,
              ),
              onResizeStart: (details) => _startResize(details, target),
              onResizeUpdate: (details) => _updateResize(details, size, padding),
              onResizeEnd: _endResize,
            ),
          );
        }),
      ],
    );
  }
}

class _MiniPlayerSurface extends StatefulWidget {
  const _MiniPlayerSurface({
    required this.service,
    required this.onMoveStart,
    required this.onMoveUpdate,
    required this.onMoveEnd,
    required this.onResizeStart,
    required this.onResizeUpdate,
    required this.onResizeEnd,
    super.key,
  });

  final MiniPlayerService service;
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
  static const Duration _controlsHideDelay = Duration(seconds: 4);
  static const Duration _controlsFadeDuration = Duration(milliseconds: 160);

  Timer? _controlsHideTimer;
  bool _controlsVisible = false;

  @override
  void dispose() {
    _controlsHideTimer?.cancel();
    super.dispose();
  }

  void _setControlsVisible(bool visible) {
    if (!mounted || _controlsVisible == visible) {
      return;
    }
    setState(() {
      _controlsVisible = visible;
    });
  }

  void _scheduleControlsHide() {
    _controlsHideTimer?.cancel();
    if (!_controlsVisible) {
      return;
    }
    _controlsHideTimer = Timer(_controlsHideDelay, () {
      _setControlsVisible(false);
    });
  }

  void _showControls() {
    if (widget.service.isEntering || widget.service.isRestoring) {
      return;
    }
    _setControlsVisible(true);
    _scheduleControlsHide();
  }

  void _togglePlayback() {
    if (widget.service.isEntering || widget.service.isRestoring) {
      return;
    }
    final controller = widget.service.snapshot.value?.plPlayerController;
    if (controller == null) {
      return;
    }
    if (controller.playerStatus.isPlaying) {
      controller.pause();
    } else {
      controller.play();
    }
    _scheduleControlsHide();
  }

  void _handleMoveStart(DragStartDetails details) {
    _controlsHideTimer?.cancel();
    widget.onMoveStart(details);
  }

  void _handleMoveUpdate(DragUpdateDetails details) {
    widget.onMoveUpdate(details);
  }

  void _handleMoveEnd(DragEndDetails details) {
    widget.onMoveEnd(details);
    _scheduleControlsHide();
  }

  void _handleResizeStart(DragStartDetails details) {
    _controlsHideTimer?.cancel();
    widget.onResizeStart(details);
  }

  void _handleResizeUpdate(DragUpdateDetails details) {
    widget.onResizeUpdate(details);
  }

  void _handleResizeEnd(DragEndDetails details) {
    widget.onResizeEnd(details);
    _scheduleControlsHide();
  }

  Widget _buildVideoLayer(MiniPlayerSnapshot snapshot) {
    final controller = snapshot.plPlayerController;
    final videoController = controller.videoController;
    return Obx(() {
      if (videoController != null) {
        final videoFit = controller.videoFit.value;
        return FittedBox(
          fit: videoFit.boxFit,
          child: SimpleVideo(
            controller: videoController,
            fill: Colors.black,
            aspectRatio: videoFit.aspectRatio,
          ),
        );
      }
      return LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth.isFinite
              ? constraints.maxWidth
              : 420.0;
          final height = constraints.maxHeight.isFinite
              ? constraints.maxHeight
              : width / Style.aspectRatio16x9;
          if (snapshot.cover.isEmpty) {
            return const ColoredBox(color: Colors.black);
          }
          return NetworkImgLayer(
            src: snapshot.cover,
            width: width,
            height: height,
            quality: 60,
            borderRadius: BorderRadius.zero,
          );
        },
      );
    });
  }

  Widget _buildHiddenLoadingLayer(ColorScheme colorScheme) {
    return IgnorePointer(
      child: Center(
        child: Obx(() {
          if (_controlsVisible ||
              !widget.service.loading.value ||
              widget.service.entering.value ||
              widget.service.restoring.value) {
            return const SizedBox.shrink();
          }
          return SizedBox.square(
            dimension: 34,
            child: CircularProgressIndicator(
              strokeWidth: 3,
              color: colorScheme.primary,
            ),
          );
        }),
      ),
    );
  }

  Widget _buildControlsLayer(
    MiniPlayerSnapshot snapshot,
    ColorScheme colorScheme,
  ) {
    final controller = snapshot.plPlayerController;
    return Obx(() {
      final transitioning =
          widget.service.entering.value || widget.service.restoring.value;
      final visible = _controlsVisible && !transitioning;
      return IgnorePointer(
        ignoring: !visible,
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: _controlsFadeDuration,
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
                child: _MiniResizeHandle(
                  onPanStart: _handleResizeStart,
                  onPanUpdate: _handleResizeUpdate,
                  onPanEnd: _handleResizeEnd,
                ),
              ),
              Positioned(
                top: 6,
                right: 6,
                child: _MiniIconButton(
                  tooltip: '关闭小窗',
                  icon: Icons.close,
                  onPressed: () {
                    _controlsHideTimer?.cancel();
                    widget.service.close();
                  },
                ),
              ),
              Center(
                child: Obx(() {
                  if (widget.service.loading.value) {
                    return SizedBox.square(
                      dimension: 34,
                      child: CircularProgressIndicator(
                        strokeWidth: 3,
                        color: colorScheme.primary,
                      ),
                    );
                  }
                  final isPlaying = controller.playerStatus.isPlaying;
                  return _MiniIconButton(
                    tooltip: isPlaying ? '暂停' : '播放',
                    icon: isPlaying ? Icons.pause : Icons.play_arrow,
                    size: 40,
                    iconSize: 26,
                    onPressed: _togglePlayback,
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
                      Text(
                        snapshot.title.isEmpty ? '正在播放' : snapshot.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Obx(() {
                        final total = controller.duration.value;
                        final progress = controller.position.value.clamp(
                          0,
                          total == 0 ? 0 : total,
                        );
                        final fraction = total == 0 ? 0.0 : progress / total;
                        return Row(
                          children: [
                            Expanded(
                              child: ClipRRect(
                                borderRadius: const BorderRadius.all(
                                  Radius.circular(999),
                                ),
                                child: LinearProgressIndicator(
                                  minHeight: 3,
                                  value: fraction,
                                  backgroundColor: Colors.white.withValues(
                                    alpha: 0.28,
                                  ),
                                  color: colorScheme.primary,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              DurationUtils.formatDuration(progress / 1000),
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
    });
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = widget.service.snapshot.value!;
    final colorScheme = ColorScheme.of(context);

    return Material(
      type: MaterialType.transparency,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black,
          borderRadius: const BorderRadius.all(Radius.circular(8)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.28),
              blurRadius: 24,
              offset: const Offset(0, 12),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: const BorderRadius.all(Radius.circular(8)),
          child: Stack(
            fit: StackFit.expand,
            children: [
              _buildVideoLayer(snapshot),
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _togglePlayback,
                  onLongPress: _showControls,
                  onPanStart: _handleMoveStart,
                  onPanUpdate: _handleMoveUpdate,
                  onPanEnd: _handleMoveEnd,
                ),
              ),
              _buildHiddenLoadingLayer(colorScheme),
              _buildControlsLayer(snapshot, colorScheme),
            ],
          ),
        ),
      ),
    );
  }
}

class _MiniResizeHandle extends StatelessWidget {
  const _MiniResizeHandle({
    required this.onPanStart,
    required this.onPanUpdate,
    required this.onPanEnd,
  });

  final GestureDragStartCallback onPanStart;
  final GestureDragUpdateCallback onPanUpdate;
  final GestureDragEndCallback onPanEnd;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '拖动调整大小',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: onPanStart,
        onPanUpdate: onPanUpdate,
        onPanEnd: onPanEnd,
        child: Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.52),
            borderRadius: const BorderRadius.all(Radius.circular(6)),
          ),
          child: const Icon(
            Icons.open_in_full,
            size: 17,
            color: Colors.white,
          ),
        ),
      ),
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
    return Tooltip(
      message: tooltip,
      child: SizedBox.square(
        dimension: size,
        child: IconButton.filledTonal(
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
      ),
    );
  }
}
