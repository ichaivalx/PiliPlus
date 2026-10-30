import 'package:PiliPlus/services/mini_player/mini_player_session.dart';
import 'package:flutter/widgets.dart';

/// 以 platform view 显示的内容（如 WebView）：挂载期间向小窗登记其所在的
/// 路由。截图不含 platform view 的内容，其上方展开时以实时页面为背景
class MiniPlayerPlatformView extends StatefulWidget {
  const MiniPlayerPlatformView({super.key, required this.child});

  final Widget child;

  /// 页面出栈时的收尾（如移除 platform view）：所在路由正作为小窗展开的
  /// 实时背景时推迟到其真正离开时执行，否则立即执行
  static void onPop(BuildContext context, VoidCallback teardown) {
    if (!miniPlayerSession.deferPopTeardown(ModalRoute.of(context), teardown)) {
      teardown();
    }
  }

  @override
  State<MiniPlayerPlatformView> createState() => _MiniPlayerPlatformViewState();
}

class _MiniPlayerPlatformViewState extends State<MiniPlayerPlatformView> {
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    miniPlayerSession.registerPlatformView(this, ModalRoute.of(context));
  }

  @override
  void dispose() {
    miniPlayerSession.unregisterPlatformView(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
