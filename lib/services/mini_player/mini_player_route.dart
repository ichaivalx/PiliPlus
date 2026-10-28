import 'package:PiliPlus/pages/video/view.dart';
import 'package:PiliPlus/services/mini_player/mini_player_policy.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

/// 从小窗恢复的详情页：进入时与小窗动画同步淡入，不做缩放，
/// 进入后与其他页面使用相同的转场
class MiniPlayerRestoreRoute extends GetPageRoute<void> {
  MiniPlayerRestoreRoute(Map<String, dynamic> arguments)
    : super(
        page: () => const VideoDetailPageV(),
        routeName: MiniPlayerPolicy.videoRoute,
        settings: RouteSettings(
          name: MiniPlayerPolicy.videoRoute,
          arguments: arguments,
        ),
      );

  bool _entered = false;
  Animation<double>? _enterOpacity;

  @override
  Duration get transitionDuration => MiniPlayerMotion.duration;

  @override
  TickerFuture didPush() {
    final future = super.didPush();
    future.whenCompleteOrCancel(() {
      if (isActive) {
        setState(() => _entered = true);
      }
    });
    return future;
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    // 结构保持不变，进入完成后改用默认转场
    return FadeTransition(
      opacity: _entered
          ? kAlwaysCompleteAnimation
          : _enterOpacity ??= CurvedAnimation(
              parent: animation,
              curve: MiniPlayerMotion.curve,
            ),
      child: super.buildTransitions(
        context,
        _entered ? animation : kAlwaysCompleteAnimation,
        secondaryAnimation,
        child,
      ),
    );
  }
}
