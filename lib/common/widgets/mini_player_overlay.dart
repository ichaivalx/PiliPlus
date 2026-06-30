import 'dart:ui';

import 'package:PiliPlus/common/style.dart';
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
  bool _restoreAnimating = false;

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
    _controller.dispose();
    super.dispose();
  }

  Rect _miniRect(Size size, EdgeInsets padding) {
    final width = clampDouble(size.width * 0.3, 300, 420);
    final height = width / Style.aspectRatio16x9;
    return Rect.fromLTWH(
      size.width - padding.right - width - 24,
      size.height - padding.bottom - height - 24,
      width,
      height,
    );
  }

  void _ensureForwardAnimation(Rect target) {
    if (_targetRect == target && _controller.isAnimating) {
      return;
    }
    final snapshot = _service.snapshot.value;
    _beginRect = _lastPaintRect ?? snapshot?.sourceRect ?? target;
    _targetRect = target;
    _controller.forward(from: 0);
  }

  Future<void> _restore(Rect target) async {
    if (_restoreAnimating) {
      return;
    }
    if (!_service.beginRestore()) {
      return;
    }
    _restoreAnimating = true;
    _beginRect = _lastPaintRect ?? target;
    _targetRect = _service.snapshot.value?.sourceRect ?? target;
    try {
      await _controller.reverse(from: 1);
      if (mounted) {
        _service.restore();
      }
    } finally {
      _restoreAnimating = false;
    }
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
            _beginRect = null;
            _targetRect = null;
            _lastPaintRect = null;
            return const SizedBox.shrink();
          }

          final mediaQuery = MediaQuery.of(context);
          final target = _miniRect(mediaQuery.size, mediaQuery.viewPadding);
          _ensureForwardAnimation(target);

          return AnimatedBuilder(
            animation: _controller,
            builder: (context, child) {
              final curve = Curves.easeOutCubic.transform(_controller.value);
              final rect = Rect.lerp(
                _beginRect ?? target,
                _targetRect ?? target,
                curve,
              )!;
              _lastPaintRect = rect;
              return Positioned.fromRect(
                rect: rect,
                child: child!,
              );
            },
            child: _MiniPlayerSurface(
              service: _service,
              onRestore: () {
                _restore(target);
              },
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
  });

  final MiniPlayerService service;
  final VoidCallback onRestore;

  @override
  Widget build(BuildContext context) {
    final snapshot = service.snapshot.value!;
    final controller = snapshot.plPlayerController;
    final videoController = controller.videoController;
    final colorScheme = ColorScheme.of(context);

    return Material(
      type: MaterialType.transparency,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onRestore,
        onVerticalDragEnd: (details) {
          if ((details.primaryVelocity ?? 0) < -240) {
            onRestore();
          }
        },
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
                if (videoController != null)
                  Obx(() {
                    final videoFit = controller.videoFit.value;
                    return FittedBox(
                      fit: videoFit.boxFit,
                      child: SimpleVideo(
                        controller: videoController,
                        fill: Colors.black,
                        aspectRatio: videoFit.aspectRatio,
                      ),
                    );
                  })
                else
                  const ColoredBox(color: Colors.black),
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
                Positioned(
                  top: 6,
                  right: 6,
                  child: _MiniIconButton(
                    tooltip: '关闭小窗',
                    icon: Icons.close,
                    onPressed: service.close,
                  ),
                ),
                Center(
                  child: Obx(() {
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
              ],
            ),
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
