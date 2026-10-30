import 'package:PiliPlus/services/mini_player/mini_player_host_layer.dart';
import 'package:PiliPlus/services/mini_player/mini_player_policy.dart';
import 'package:PiliPlus/services/mini_player/mini_player_session.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

/// 详情页在浏览历史中的位置：本身不绘制，透过它看到下方宿主层中的详情页。
/// 详情页的弹窗、面板照常推入浏览栈，位于其上方；返回、出栈先交给详情页
/// 自身的面板与 PopScope，再由会话决定收起、关闭或回到上一个视频
///
/// 宿主释放后保留为旧视频的记录（[isDormant]），重新露出时由会话重新打开
///
/// 路由参数即为所呈现详情页的参数，重新打开旧视频时原地更新
class MiniPlayerWindowRoute extends GetPageRoute<void> {
  MiniPlayerWindowRoute(
    Map<String, dynamic> arguments, {
    MiniPlayerHostEntry? host,
    bool presentation = false,
  }) : _host = host,
       _presentation = presentation,
       _overBackdrop = presentation,
       super(
         page: () => const SizedBox.expand(),
         routeName: MiniPlayerPolicy.videoRoute,
         settings: RouteSettings(
           name: MiniPlayerPolicy.videoRoute,
           arguments: arguments,
         ),
       );

  MiniPlayerHostEntry? _host;

  /// 当前通过本窗口呈现的宿主，null 表示没有宿主
  MiniPlayerHostEntry? get host => _host;
  set host(MiniPlayerHostEntry? value) {
    if (!identical(_host, value)) {
      _host = value;
      value?.presentationChanged();
    }
  }

  Map<String, dynamic> get arguments =>
      settings.arguments! as Map<String, dynamic>;

  /// 宿主释放后保留的旧视频，重新露出时据此重新打开
  MiniPlayerDormant? dormant;

  bool get isDormant => _host == null && dormant != null;

  /// 从小窗展开时临时推入的窗口：不播放转场，下方页面保持不动，展开期间
  /// 下方页面作为实时背景保持显示，展开结束后由 [reveal] 遮住
  bool _presentation;
  bool _overBackdrop;

  /// 会话主动出栈，不再交给详情页与会话判断
  bool _leaving = false;

  /// 出栈时详情页按离开处理（暂停等）
  bool forwardPop = false;

  @override
  bool get opaque => !_overBackdrop;

  /// 本窗口遮住下方页面，宿主中的详情页显示
  void reveal() {
    if (!_overBackdrop) {
      return;
    }
    _overBackdrop = false;
    if (isActive && overlayEntries.isNotEmpty) {
      overlayEntries.first.opaque = true;
    }
  }

  /// 从详情页打开其他页面后成为详情页的位置，之后与打开视频时的窗口相同
  void settle() {
    reveal();
    _presentation = false;
  }

  /// 由会话出栈，[NavigatorState.pop] 直接移除本窗口
  void leave() => _leaving = true;

  @override
  Duration get transitionDuration =>
      _presentation ? Duration.zero : super.transitionDuration;

  @override
  Duration get reverseTransitionDuration => super.transitionDuration;

  @override
  bool canTransitionFrom(TransitionRoute<dynamic> previousRoute) =>
      !_presentation && super.canTransitionFrom(previousRoute);

  @override
  Widget buildModalBarrier() => const SizedBox.shrink();

  /// 转场由宿主中的详情页以 [buildPresentation] 绘制
  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => child;

  /// 本窗口的转场，作用于宿主中的详情页；含下一个页面委托的转场
  Widget buildPresentation(BuildContext context, Widget child) {
    final animation = this.animation!;
    final secondaryAnimation = this.secondaryAnimation!;
    final received = receivedTransition;
    if (received == null) {
      return super.buildTransitions(
        context,
        animation,
        secondaryAnimation,
        child,
      );
    }
    final original = super.buildTransitions(
      context,
      animation,
      kAlwaysDismissedAnimation,
      child,
    );
    return received(
          context,
          animation,
          secondaryAnimation,
          allowSnapshotting,
          original,
        ) ??
        original;
  }

  @override
  void didChangeNext(Route<dynamic>? nextRoute) {
    super.didChangeNext(nextRoute);
    _host?.presentationChanged();
  }

  @override
  void didPopNext(Route<dynamic> nextRoute) {
    super.didPopNext(nextRoute);
    _host?.presentationChanged();
  }

  Route<dynamic>? get _detail => _host?.route;

  @override
  bool get willHandlePopInternally =>
      super.willHandlePopInternally ||
      (_detail?.willHandlePopInternally ?? false);

  @override
  RoutePopDisposition get popDisposition {
    if (_detail?.popDisposition == RoutePopDisposition.doNotPop ||
        miniPlayerSession.blocksBack(this)) {
      return RoutePopDisposition.doNotPop;
    }
    return super.popDisposition;
  }

  @override
  bool get popGestureEnabled =>
      super.popGestureEnabled && miniPlayerSession.allowsPopGesture(this);

  @override
  void onPopInvokedWithResult(bool didPop, void result) {
    super.onPopInvokedWithResult(didPop, result);
    final detail = _detail;
    if (detail is! ModalRoute) {
      return;
    }
    if (didPop) {
      if (forwardPop) {
        detail.onPopInvokedWithResult(true, null);
      }
    } else if (detail.popDisposition == RoutePopDisposition.doNotPop) {
      detail.onPopInvokedWithResult(false, null);
    }
  }

  /// 先关闭详情页中的面板（本地历史），再由会话决定是否出栈
  @override
  bool didPop(void result) {
    if (!_leaving) {
      final detail = _detail;
      if (detail != null && detail.willHandlePopInternally) {
        // ignore: invalid_use_of_protected_member
        detail.didPop(null);
        return false;
      }
      if (!miniPlayerSession.allowWindowPop(this)) {
        return false;
      }
    }
    return super.didPop(result);
  }

  @override
  void dispose() {
    miniPlayerSession.windowDisposed(this);
    super.dispose();
  }
}

/// 宿主释放后保留的旧视频：重新打开所用的参数，及离开时是否在播放
class MiniPlayerDormant {
  const MiniPlayerDormant(this.args, {required this.playing});

  final Map<String, dynamic> args;
  final bool playing;
}
