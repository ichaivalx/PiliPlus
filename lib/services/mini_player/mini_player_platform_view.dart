import 'package:PiliPlus/services/mini_player/mini_player_session.dart';
import 'package:flutter/widgets.dart';

/// 以 platform view 显示的内容（如 WebView）：挂载期间向小窗登记其所在的
/// 路由。截图不含 platform view 的内容，其上方展开时以实时页面为背景
class MiniPlayerPlatformView extends StatefulWidget {
  const MiniPlayerPlatformView({super.key, required this.child});

  final Widget child;

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
