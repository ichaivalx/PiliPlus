import 'package:PiliPlus/services/mini_player/mini_player_session.dart';
import 'package:flutter/widgets.dart';

/// 需排在 routeObserver 之前，保证页面收到 didPushNext 时小窗已接管
final miniPlayerRouteObserver = _MiniPlayerRouteObserver();

class _MiniPlayerRouteObserver extends NavigatorObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      miniPlayerSession.didPush(route, previousRoute);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      miniPlayerSession.didPop(route, previousRoute);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      miniPlayerSession.didRemove(route, previousRoute);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      miniPlayerSession.didReplace(newRoute: newRoute, oldRoute: oldRoute);
}
