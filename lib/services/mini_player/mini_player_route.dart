import 'package:PiliPlus/pages/video/view.dart';
import 'package:PiliPlus/services/mini_player/mini_player_policy.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

/// 从小窗恢复的详情页：进入时没有转场，由小窗层将页面从小窗的位置展开；
/// 返回时与其他页面使用相同的转场
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

  @override
  Duration get transitionDuration => Duration.zero;

  @override
  Duration get reverseTransitionDuration => super.transitionDuration;
}
