import 'package:PiliPlus/services/mini_player/mini_player_host_layer.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get_core/src/get_main.dart';
import 'package:get/get_navigation/src/extension_navigation.dart';
import 'package:get/get_navigation/src/routes/default_route.dart'
    show GetPageRoute;

final routeObserver = RouteObserver<GetPageRoute>();

mixin RouteAwareMixin<T extends StatefulWidget> on State<T>, RouteAware {
  @override
  void initState() {
    super.initState();
    // 宿主中的详情页由小窗会话按其显示状态通知
    if (MiniPlayerHostScope.maybeOf(context) == null) {
      routeObserver.subscribe(this, Get.routing.route as GetPageRoute);
    }
  }

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    super.dispose();
  }
}
