import 'package:PiliPlus/pages/video/view.dart';
import 'package:PiliPlus/services/mini_player/mini_player_policy.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

/// 从小窗恢复的详情页：进入时没有转场，由小窗层将页面从小窗的位置展开；
/// 返回时与其他页面使用相同的转场
class MiniPlayerRestoreRoute extends GetPageRoute<void> {
  MiniPlayerRestoreRoute(
    Map<String, dynamic> arguments, {
    bool overBackdrop = false,
  }) : _overBackdrop = ValueNotifier(overBackdrop),
       super(
         page: () => const VideoDetailPageV(),
         routeName: MiniPlayerPolicy.videoRoute,
         settings: RouteSettings(
           name: MiniPlayerPolicy.videoRoute,
           arguments: arguments,
         ),
       );

  /// 展开期间下方页面作为实时背景保持显示，本页不可见，但照常布局与绘制，
  /// 供小窗层截图；展开结束后由 [reveal] 恢复
  final ValueNotifier<bool> _overBackdrop;

  @override
  bool get opaque => !_overBackdrop.value;

  /// 本页覆盖下方页面并显示
  void reveal() {
    if (!isActive || !_overBackdrop.value) {
      return;
    }
    _overBackdrop.value = false;
    if (overlayEntries.isNotEmpty) {
      overlayEntries.first.opaque = true;
    }
  }

  @override
  Duration get transitionDuration => Duration.zero;

  @override
  Duration get reverseTransitionDuration => super.transitionDuration;

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => ValueListenableBuilder<bool>(
    valueListenable: _overBackdrop,
    builder: (context, hidden, child) => ClipRect(
      clipper: hidden ? const _EmptyClipper() : null,
      clipBehavior: hidden ? Clip.hardEdge : Clip.none,
      child: child,
    ),
    child: super.buildTransitions(
      context,
      animation,
      secondaryAnimation,
      child,
    ),
  );

  @override
  void dispose() {
    _overBackdrop.dispose();
    super.dispose();
  }
}

class _EmptyClipper extends CustomClipper<Rect> {
  const _EmptyClipper();

  @override
  Rect getClip(Size size) => Rect.zero;

  @override
  bool shouldReclip(_EmptyClipper oldClipper) => false;
}
