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
      size.width * 0.36,
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

  Widget _restoreRevealScrim(BuildContext context) {
    return IgnorePointer(
      child: ColoredBox(
        color: Theme.of(context).scaffoldBackgroundColor.withValues(
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

  void _endMove(DragEndDetails details, Rect current) {
    final velocity = details.velocity.pixelsPerSecond;
    final shouldRestore =
        velocity.dy < -650 && velocity.dy.abs() > velocity.dx.abs() * 1.2;
    _moving = false;
    _moveStartPoint = null;
    _moveStartRect = null;
    if (shouldRestore) {
      _restore(_lastPaintRect ?? current);
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
                  if (_service.restoring.value) _restoreRevealScrim(context),
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
              onRestore: () => _restore(target),
              onMoveStart: (details) => _startMove(details, target),
              onMoveUpdate: (details) => _updateMove(details, size, padding),
              onMoveEnd: (details) => _endMove(details, target),
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

class _MiniPlayerSurface extends StatelessWidget {
  const _MiniPlayerSurface({
    required this.service,
    required this.onRestore,
    required this.onMoveStart,
    required this.onMoveUpdate,
    required this.onMoveEnd,
    required this.onResizeStart,
    required this.onResizeUpdate,
    required this.onResizeEnd,
    super.key,
  });

  final MiniPlayerService service;
  final VoidCallback onRestore;
  final GestureDragStartCallback onMoveStart;
  final GestureDragUpdateCallback onMoveUpdate;
  final GestureDragEndCallback onMoveEnd;
  final GestureDragStartCallback onResizeStart;
  final GestureDragUpdateCallback onResizeUpdate;
  final GestureDragEndCallback onResizeEnd;

  @override
  Widget build(BuildContext context) {
    final snapshot = service.snapshot.value!;
    final controller = snapshot.plPlayerController;
    final videoController = controller.videoController;
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
              Obx(() {
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
              }),
              DecoratedBox(
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
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onRestore,
                  onPanStart: onMoveStart,
                  onPanUpdate: onMoveUpdate,
                  onPanEnd: onMoveEnd,
                ),
              ),
              Positioned(
                top: 6,
                left: 6,
                child: Obx(
                  () => service.entering.value || service.restoring.value
                      ? const SizedBox.shrink()
                      : _MiniResizeHandle(
                          onPanStart: onResizeStart,
                          onPanUpdate: onResizeUpdate,
                          onPanEnd: onResizeEnd,
                        ),
                ),
              ),
              Positioned(
                top: 6,
                right: 6,
                child: Obx(
                  () => service.entering.value || service.restoring.value
                      ? const SizedBox.shrink()
                      : _MiniIconButton(
                          tooltip: '关闭小窗',
                          icon: Icons.close,
                          onPressed: service.close,
                        ),
                ),
              ),
              Center(
                child: Obx(() {
                  if (service.entering.value || service.restoring.value) {
                    return const SizedBox.shrink();
                  }
                  if (service.loading.value) {
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
                    onPressed: () {
                      if (isPlaying) {
                        controller.pause();
                      } else {
                        controller.play();
                      }
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
