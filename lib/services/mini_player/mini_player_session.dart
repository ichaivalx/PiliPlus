import 'dart:async' show unawaited;
import 'dart:ui' as ui;

import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/services/mini_player/mini_player_host_layer.dart';
import 'package:PiliPlus/services/mini_player/mini_player_policy.dart';
import 'package:PiliPlus/services/mini_player/mini_player_window.dart';
import 'package:PiliPlus/services/shutdown_timer_service.dart';
import 'package:PiliPlus/utils/reply_scheme_helper.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:collection/collection.dart' show IterableExtension;
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:get/get_navigation/src/router_report.dart';

/// 视频详情页提供给小窗的能力
abstract interface class MiniPlayerHost {
  /// 当前页面持有播放器且满足小窗条件
  bool get canEnterMiniPlayer;

  /// 播放器在页面中的位置，尚未完成布局时为 null
  Rect? get miniPlayerRect;

  /// 收起、展开时代替页面绘制的截图
  ui.Image? captureMiniSnapshot();
  String get miniTitle;
  String get miniCover;

  /// 当前播放的内容，用于判断打开的是否为同一视频，也是保留为旧视频记录
  /// 时重新打开所用的参数
  Map<String, dynamic> get miniArgs;

  /// 播放器尚未开始播放当前内容
  bool get isMiniPlayerLoading;

  /// 各区域所需的内容到达（或等待超时）后完成
  Future<void> whenMiniContentReady();

  /// 收起为小窗，页面不再显示
  void onMiniCollapsed();

  /// 从小窗展开，页面重新显示
  void onMiniExpanded();

  /// 被页面覆盖且未转入小窗，按离开处理
  void onMiniHidden();

  /// 重新成为最上层的页面
  void onMiniRevealed();

  /// 小窗关闭后页面留在历史中，按离开处理
  void onMiniStopped({required bool resumeOnReturn});

  /// 其他详情页即将接管播放器，作废续播并停止监听
  void onMiniDetached();

  /// 其他详情页离开后接管播放器并开始加载
  void takeOverPlayer();
}

enum MiniPlayerMode { none, mini }

final miniPlayerSession = MiniPlayerSession._();

class MiniPlayerSession {
  MiniPlayerSession._() {
    // 小窗存在期间不自动进入系统画中画
    mode.listen((_) => PlPlayerController.instance?.updateAutoEnterPip());
  }

  final Rx<MiniPlayerMode> mode = MiniPlayerMode.none.obs;

  /// 从小窗展开（或小窗飞回露出的播放器）的过程
  final RxBool restoring = false.obs;
  final Rxn<Rect> restoreRect = Rxn<Rect>();
  Rect? enterRect;
  ui.Image? _enterSnapshot;

  /// 展开或回到上一个视频前等待页面内容
  final RxBool _gating = false.obs;

  /// 宿主页面接入，小窗的标题、封面随之更新
  final RxInt _revision = 0.obs;

  /// 宿主层中的各宿主，通常只有一个；切换视频的转场期间新旧同时存在
  final List<MiniPlayerHostEntry> hosts = [];
  final layer = _LayerNotifier();

  /// 当前的宿主，播放器属于它
  MiniPlayerHostEntry? _host;

  final List<Route<dynamic>> _routes = [];
  final Set<MiniPlayerWindowRoute> _leaving = {};
  bool _settling = false;
  ValueListenable<bool>? _userGesture;

  /// 等待上一个视频的内容到达后再出栈
  _DormantGate? _gate;

  /// 浏览页下方紧邻旧视频记录时拦截其返回，见 [_syncDormantEntry]
  _DormantPopEntry? _dormantEntry;

  /// 主动恢复与返回键回到详情页的位置时，详情页从小窗展开；手势返回时
  /// 详情页已随拖动露出，小窗飞回播放器的位置
  bool _expandRestore = false;
  bool get expandRestore => _expandRestore;

  /// 展开时以恢复前的画面截图为背景（返回键回到详情页的位置，上层页面随即
  /// 离开）；其余情况下层页面保持实时显示
  bool _snapshotRestore = false;
  bool get snapshotRestore => _snapshotRestore;

  bool _liveBackdrop = false;
  bool get liveBackdrop => _liveBackdrop;

  bool get isActive => mode.value == .mini;

  bool get isLoading {
    _revision.value;
    return _gating.value || (_host?.page?.isMiniPlayerLoading ?? false);
  }

  String get title {
    _revision.value;
    final host = _host;
    return host?.page?.miniTitle ?? host?.args['title'] ?? '';
  }

  String get cover {
    _revision.value;
    final host = _host;
    return host?.page?.miniCover ?? host?.args['cover'] ?? '';
  }

  /// 展开的终点页面当前的截图，由小窗层取走并负责释放
  ui.Image? captureRestorePage() => _host?.page?.captureMiniSnapshot();

  /// 收起时的页面截图，由小窗取走并负责释放
  ui.Image? takeEnterSnapshot() {
    final snapshot = _enterSnapshot;
    _enterSnapshot = null;
    return snapshot;
  }

  MiniPlayerHostEntry? _hostOf(MiniPlayerHost page) {
    for (final host in hosts) {
      if (identical(host.page, page)) {
        return host;
      }
    }
    return null;
  }

  void attach(MiniPlayerHostEntry host, MiniPlayerHost page) {
    host.attach(page);
    _revision.value++;
  }

  void detach(MiniPlayerHost page) {
    for (final host in hosts) {
      host.detach(page);
    }
    _revision.value++;
    if ((PlPlayerController.instance?.isCloseAll ?? false) &&
        _host != null) {
      // 返回主页时播放器已被整体销毁，页面移除期间不修改宿主层
      Future.microtask(() {
        for (final host in hosts.toList()) {
          _release(host);
        }
      });
    }
  }

  /// 宿主中的页面在其之外创建的控制器属于该页面，随宿主释放
  T bindToDetail<T>(String heroTag, T Function() create) {
    final host = hosts.firstWhereOrNull((e) => e.heroTag == heroTag);
    if (host == null) {
      return create();
    }
    RouterReportManager.reportCurrentRoute(host.route);
    try {
      return create();
    } finally {
      syncCurrentRoute();
    }
  }

  /// 依赖按当前路由归属：最上层为显示详情页的窗口时归属详情页
  void syncCurrentRoute() {
    final top = _routes.lastOrNull;
    if (top == null) {
      return;
    }
    final host = _host;
    if (host != null && identical(host.window, top)) {
      RouterReportManager.reportCurrentRoute(host.route);
    } else {
      RouterReportManager.reportCurrentRoute(top);
    }
  }

  // 打开视频

  /// 宿主模式下打开视频详情页，返回 false 时按上游方式打开
  bool openVideo(Map arguments, {required bool off}) {
    if (!MiniPlayerPolicy.hostsDetail(arguments)) {
      return false;
    }
    final args = Map<String, dynamic>.from(arguments);
    final host = _host;
    if (host != null && isActive) {
      final content = host.page?.miniArgs ?? host.args;
      if (content['bvid'] == args['bvid'] && content['cid'] == args['cid']) {
        if (_isSameList(args, content)) {
          unawaited(restore());
          return true;
        }
        // 换列表按普通方式打开，从小窗的当前进度继续；已播完时按入口参数
        if (PlPlayerController.instance case final player?
            when !player.playerStatus.isCompleted) {
          args['progress'] = player.positionInMilliseconds;
        }
      } else if (!off &&
          !_hasIntent(args) &&
          args['progress'] == null &&
          !restoring.value) {
        _switchInMini(args);
        return true;
      }
    }
    _open(args, off: off && allowsReplace);
    return true;
  }

  /// 打开视频时可以替换最上层的页面：最上层为显示中的详情页或普通页面；
  /// 小窗或被覆盖的详情页发起时不替换用户所在的页面
  bool get allowsReplace {
    final host = _host;
    return host == null ||
        (host.state == .shown && identical(host.window, _routes.lastOrNull));
  }

  /// 定位评论的请求按普通方式打开详情页
  static bool _hasIntent(Map args) =>
      args[rootRpIdKey] != null || args[secondRpIdKey] != null;

  /// 决定播放列表来源与顺序的参数
  static const _listKeys = [
    'sourceType',
    'mediaId',
    'mediaType',
    'desc',
    'sortField',
  ];

  static bool _isSameList(Map args, Map content) =>
      _listKeys.every((key) => args[key] == content[key]);

  void _open(Map<String, dynamic> args, {required bool off}) {
    final navigator = Get.key.currentState;
    if (navigator == null) {
      return;
    }
    final previous = _host;
    final host = MiniPlayerHostEntry(args);
    final window = MiniPlayerWindowRoute(args, host: host);
    host.anchor = window;
    if (previous != null) {
      _leave(previous, replaced: off);
    }
    _host = host;
    hosts.add(host);
    layer.notify();
    if (off) {
      navigator.pushReplacement(window);
    } else {
      navigator.push(window);
    }
  }

  /// 打开其他视频后，原详情页保留为历史中的旧视频记录：显示中的在新视频
  /// 入场期间仍在其下方显示，入场结束后释放；[replaced] 时其窗口被替换，
  /// 随之释放
  void _leave(MiniPlayerHostEntry host, {required bool replaced}) {
    final dormant = _dormantArgs(host);
    switch (host.state) {
      case .shown:
        host
          ..state = .outgoing
          ..page?.onMiniHidden();
        if (!replaced) {
          host.window?.dormant = dormant;
        }
      case .mini:
        _start();
        mode.value = .none;
        host.page?.onMiniDetached();
        _keepDormant(host, dormant);
      case .parked || .outgoing || .closing:
        _keepDormant(host, dormant);
    }
  }

  /// 重新打开旧视频所用的参数：从离开时的进度继续，不再定位评论
  Map<String, dynamic> _dormantArgs(MiniPlayerHostEntry host) {
    final args = <String, dynamic>{...(host.page?.miniArgs ?? host.args)}
      ..remove(rootRpIdKey)
      ..remove(secondRpIdKey);
    if (PlPlayerController.instance case final player?
        when PlPlayerController.playOwner?.tag == host.heroTag &&
            !player.playerStatus.isCompleted) {
      args['progress'] = player.positionInMilliseconds;
    } else {
      args.remove('progress');
    }
    return args;
  }

  /// 释放宿主，其所在的位置保留为旧视频记录
  void _keepDormant(MiniPlayerHostEntry host, Map<String, dynamic> dormant) {
    final window = host.window;
    if (window != null && window.isActive) {
      window
        ..host = null
        ..dormant = dormant;
      final anchor = host.anchor;
      if (host.presented != null && anchor != null) {
        // 只保留一条记录
        anchor.host = null;
        Future.microtask(() => _removeRoute(anchor));
      }
      host
        ..anchor = null
        ..presented = null;
    }
    _release(host);
  }

  /// 小窗中切换到其他视频：新的详情页不显示地构建并接管播放器，原详情页
  /// 保留为旧视频记录
  void _switchInMini(Map<String, dynamic> args) {
    final previous = _host!;
    final dormant = _dormantArgs(previous);
    previous.page?.onMiniDetached();
    final host = MiniPlayerHostEntry(args, hidden: true)..state = .mini;
    _host = host;
    hosts.add(host);
    _keepDormant(previous, dormant);
    _revision.value++;
  }

  void _release(MiniPlayerHostEntry host) {
    hosts.remove(host);
    host.anchor?.host = null;
    host.presented?.host = null;
    host
      ..anchor = null
      ..presented = null;
    if (identical(_host, host)) {
      _host = null;
      if (isActive) {
        _start();
        mode.value = .none;
      }
    }
    layer.notify();
    // 宿主随布局移除，在其后释放
    WidgetsBinding.instance.addPostFrameCallback((_) => host.dispose());
  }

  // 路由变化

  /// 栈中最上层的不透明页面
  Route<dynamic>? _topPage({Route<dynamic>? below}) {
    var index = below == null ? _routes.length : _routes.indexOf(below);
    while (--index >= 0) {
      final route = _routes[index];
      if (route is PageRoute && route.opaque) {
        return route;
      }
    }
    return null;
  }

  Route<dynamic>? _routeBelow(Route<dynamic> route) {
    final index = _routes.indexOf(route);
    return index > 0 ? _routes[index - 1] : null;
  }

  void _track(Route<dynamic> route) {
    _routes.add(route);
    if (route is TransitionRoute) {
      route.animation?.addStatusListener(_onRouteStatus);
    }
    if (_userGesture == null) {
      final navigator = route.navigator;
      if (navigator != null && identical(navigator, Get.key.currentState)) {
        _userGesture = navigator.userGestureInProgressNotifier
          ..addListener(_updateLayer);
      }
    }
  }

  /// 被替换的窗口在新页面入场结束前仍然显示
  void _untrack(Route<dynamic> route) {
    _routes.remove(route);
    if (route is MiniPlayerWindowRoute) {
      _leaving.add(route);
    }
  }

  void _onRouteStatus(AnimationStatus status) {
    _releaseCovered();
    _updateLayer();
  }

  /// 新打开的视频入场结束，原详情页不再露出，释放并保留为旧视频记录
  void _releaseCovered() {
    for (final host in hosts.toList()) {
      final window = host.window;
      if (host.state == .outgoing &&
          window != null &&
          _routes.contains(window) &&
          !_isExposed(_routes.indexOf(window))) {
        _keepDormant(host, window.dormant ?? _dormantArgs(host));
      }
    }
  }

  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _track(route);
    _onPush(route);
    _afterRouteChange();
  }

  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _untrack(route);
    _onReveal();
    _expandOnPop(route);
    _afterRouteChange();
  }

  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _untrack(route);
    _onReveal();
    _afterRouteChange();
  }

  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final index = oldRoute == null ? -1 : _routes.indexOf(oldRoute);
    if (oldRoute != null) {
      _untrack(oldRoute);
    }
    if (newRoute != null) {
      if (index == -1) {
        _track(newRoute);
      } else {
        _routes.insert(index, newRoute);
        if (newRoute is TransitionRoute) {
          newRoute.animation?.addStatusListener(_onRouteStatus);
        }
      }
      _onPush(newRoute);
    }
    _afterRouteChange();
  }

  void _onPush(Route<dynamic> route) {
    if (route is MiniPlayerWindowRoute) {
      return;
    }
    final kind = MiniPlayerPolicy.classify(route);
    final host = _host;
    if (kind == .overlay || host == null) {
      return;
    }
    switch (host.state) {
      case .shown:
        final window = host.window;
        if (window == null || !_routes.contains(window)) {
          return;
        }
        _anchorAt(host, window);
        if (kind == .content &&
            (host.page?.canEnterMiniPlayer ?? false) &&
            (PlPlayerController.instance?.playerStatus.isPlaying ?? false)) {
          _enterMini(host);
        } else {
          host.state = .parked;
          host.page?.onMiniHidden();
        }
      case .mini:
        switch (kind) {
          case .video:
            close(pause: false);
          case .exclusive:
            // 独占播放的页面不一定使用同一播放器（如听音频），无位置时明确
            // 暂停；留在历史中的详情页由其离开处理暂停，返回时照常恢复
            close(pause: host.anchor == null);
          case _:
        }
      case _:
    }
  }

  /// 从详情页打开其他页面：详情页的位置随之移到该页面下方，原位置不再保留
  void _anchorAt(MiniPlayerHostEntry host, MiniPlayerWindowRoute window) {
    final previous = host.anchor;
    host
      ..anchor = window
      ..presented = null;
    window.settle();
    if (previous != null && !identical(previous, window)) {
      previous.host = null;
      Future.microtask(() => _removeRoute(previous));
    }
  }

  /// 详情页被内容页覆盖，播放转入小窗；页面以截图收起，覆盖它的页面照常入场
  void _enterMini(MiniPlayerHostEntry host) {
    _collapse(host);
  }

  void _collapse(MiniPlayerHostEntry host) {
    final page = host.page!;
    _start();
    enterRect = page.miniPlayerRect;
    _enterSnapshot?.dispose();
    _enterSnapshot = page.captureMiniSnapshot();
    host.state = .mini;
    page.onMiniCollapsed();
    mode.value = .mini;
    _updateLayer();
  }

  /// 重新露出独占播放器的页面时结束会话，先于该页面的 didPopNext 执行
  void _onReveal() {
    if (!isActive) {
      return;
    }
    if (_topPage() case final page?
        when MiniPlayerPolicy.classify(page) == .exclusive) {
      close();
    }
  }

  /// 返回键回到详情页的位置：与主动恢复一样由小窗展开。上层页面的出栈转场
  /// 在展开开始前直接结束（此时页面层已不可见）；回到详情页后由
  /// [_scheduleSettle] 给出展开的终点
  void _expandOnPop(Route<dynamic> route) {
    final anchor = _host?.anchor;
    if (!isActive ||
        restoring.value ||
        anchor == null ||
        route is! TransitionRoute ||
        !identical(_topPage(), anchor) ||
        (anchor.navigator?.userGestureInProgress ?? true)) {
      return;
    }
    _expandRestore = true;
    _snapshotRestore = true;
    _liveBackdrop = false;
    restoring.value = true;
    // ignore: invalid_use_of_protected_member
    final controller = route.controller;
    Future.microtask(() {
      if (controller != null && controller.isAnimating) {
        controller.value = controller.lowerBound;
      }
    });
  }

  void _afterRouteChange() {
    _releaseCovered();
    _revealParked();
    _openExposedDormant();
    _scheduleSettle();
    _syncDormantEntry();
    _updateLayer();
    // 没有宿主时（手机、桌面等）依赖归属与上游一致
    if (hosts.isNotEmpty) {
      syncCurrentRoute();
    }
  }

  /// 被覆盖的详情页重新成为最上层的页面
  void _revealParked() {
    final host = _host;
    if (host != null &&
        host.state == .parked &&
        identical(_topPage(), host.anchor)) {
      host
        ..state = .shown
        ..page?.onMiniRevealed();
    }
  }

  /// 旧视频记录未经等待直接露出（如直接出栈上层页面），立即重新打开
  void _openExposedDormant() {
    if (_topPage() case final MiniPlayerWindowRoute window
        when window.isDormant && _gate == null) {
      _openDormant(window, above: null);
    }
  }

  void _scheduleSettle() {
    final host = _host;
    if (_settling || host == null || !isActive) {
      return;
    }
    final anchor = host.anchor;
    if (anchor == null || !identical(_topPage(), anchor)) {
      if (restoring.value && host.presented == null) {
        // 详情页上方又有页面（如出栈后立即入栈），本次恢复无法完成
        _cancelRestore();
      }
      return;
    }
    _settling = true;
    Future.microtask(() {
      _settling = false;
      if (!isActive ||
          !identical(_host, host) ||
          !identical(_topPage(), host.anchor)) {
        return;
      }
      if (!restoring.value) {
        _expandRestore = false;
        _snapshotRestore = false;
        _liveBackdrop = false;
        restoring.value = true;
        _updateLayer();
      }
      _settleRestore(host);
    });
  }

  /// 详情页完成布局后给出展开的终点，小窗随之交给过渡
  void _settleRestore(MiniPlayerHostEntry host) {
    if (!restoring.value || !identical(_host, host) || !isActive) {
      return;
    }
    final rect = host.page?.miniPlayerRect;
    if (rect == null) {
      WidgetsBinding.instance
        ..addPostFrameCallback((_) => _settleRestore(host))
        ..scheduleFrame();
      return;
    }
    host.state = .shown;
    restoreRect.value = rect;
    mode.value = .none;
    _updateLayer();
  }

  // 显示

  /// 各宿主是否绘制及绘制顺序：位于窗口下方且窗口露出时绘制；窗口自身转场
  /// 期间位于浏览 Navigator 上方
  void _updateLayer() {
    final top = _routes.lastOrNull;
    for (final host in hosts) {
      final window = host.window;
      final index = window == null ? -1 : _routes.indexOf(window);
      final exposed = index == -1
          ? _leaving.contains(window)
          : _isExposed(index);
      final bool painted;
      var lifted = false;
      switch (host.state) {
        case .shown || .parked || .outgoing:
          painted = exposed;
          lifted =
              host.state == .shown &&
              identical(window, top) &&
              !(window!.animation?.isCompleted ?? true);
        case .mini:
          painted =
              exposed &&
              (restoring.value || (_userGesture?.value ?? false));
        case .closing:
          final animation = window?.animation;
          painted = lifted = animation != null && !animation.isDismissed;
      }
      host.updateLayer(
        painted: painted,
        z: lifted ? 1 : index - _routes.length - 1,
      );
    }
  }

  /// 窗口上方没有完成入场的不透明路由
  bool _isExposed(int index) {
    for (final route in _routes.skip(index + 1)) {
      if (route is TransitionRoute) {
        if (route.opaque && (route.animation?.isCompleted ?? true)) {
          return false;
        }
      } else if (route is PageRoute && route.opaque) {
        return false;
      }
    }
    return true;
  }

  // 窗口

  /// 等待上一个视频期间不响应返回
  bool blocksBack(MiniPlayerWindowRoute window) =>
      _gate != null ||
      (restoring.value && identical(window.host, _host) && !isActive);

  /// 返回只关闭详情页、露出普通页面时才允许拖动返回；收起与回到上一个
  /// 视频由返回键完成
  bool allowsPopGesture(MiniPlayerWindowRoute window) {
    final host = window.host;
    if (host == null || host.state != .shown) {
      return true;
    }
    final below = _routeBelow(window);
    return !(below is MiniPlayerWindowRoute && below.isDormant) &&
        !(host.page?.canEnterMiniPlayer ?? false);
  }

  /// 显示中的详情页出栈（返回键、Get.back 等），面板已先行关闭：
  /// 下方为旧视频时等其内容到达后回到该视频；可进入小窗时收起；否则关闭
  bool allowWindowPop(MiniPlayerWindowRoute window) {
    final host = window.host;
    if (host == null ||
        !identical(host, _host) ||
        (PlPlayerController.instance?.isCloseAll ?? false)) {
      return true;
    }
    if (host.state == .mini) {
      if (identical(host.presented, window)) {
        // 展开尚未完成，撤销
        host.presented = null;
        window.host = null;
        _cancelRestore();
      }
      return true;
    }
    if (host.state != .shown) {
      return true;
    }
    if (_gate case final gate?) {
      // 等待期间再次出栈（如逐层出栈到首页）不再等待，上一个视频直接露出
      if (identical(gate.above, window)) {
        _gate = null;
        _gating.value = false;
        return true;
      }
      return false;
    }
    if (restoring.value) {
      // 展开动画中直接出栈，按展开已完成处理
      restoring.value = false;
      restoreRect.value = null;
      host.presented?.reveal();
    }
    final below = _routeBelow(window);
    if (below is MiniPlayerWindowRoute && below.isDormant) {
      _openDormant(below, above: window);
      return false;
    }
    if (host.page?.canEnterMiniPlayer ?? false) {
      if (identical(host.anchor, window)) {
        host.anchor = null;
      } else {
        host.presented = null;
      }
      window.host = null;
      _collapse(host);
      return true;
    }
    host.state = .closing;
    window.forwardPop = true;
    return true;
  }

  void windowDisposed(MiniPlayerWindowRoute window) {
    _leaving.remove(window);
    final host = window.host;
    window.host = null;
    if (host == null) {
      return;
    }
    if (identical(host.anchor, window)) {
      host.anchor = null;
    }
    if (identical(host.presented, window)) {
      host.presented = null;
    }
    if (host.state != .mini) {
      final next = _host;
      _release(host);
      if (next != null && !identical(next, host) && next.deferPlayer) {
        next.deferPlayer = false;
        next.page?.takeOverPlayer();
      }
    }
    _updateLayer();
  }

  // 旧视频记录

  /// 重新打开旧视频：新的详情页在上层页面下方构建，内容到达后上层页面再
  /// 出栈；[above] 为 null 时已经露出，直接打开
  void _openDormant(
    MiniPlayerWindowRoute dormant, {
    required Route<dynamic>? above,
  }) {
    final args = dormant.dormant!;
    final previous = _host;
    // 接管播放器之前记下离开时的进度
    final previousDormant = previous == null ? null : _dormantArgs(previous);
    final shownAbove =
        previous != null &&
        previous.state == .shown &&
        identical(previous.window, above);
    final host = MiniPlayerHostEntry(
      {...args, 'heroTag': Utils.makeHeroTag(args['cid'])},
      hidden: above != null,
      deferPlayer: shownAbove,
    );
    dormant
      ..dormant = null
      ..host = host;
    host.anchor = dormant;
    if (previous != null) {
      if (shownAbove) {
        // 显示中的详情页随出栈转场离开后释放，期间保持暂停时的画面
        previous
          ..state = .closing
          ..page?.onMiniDetached();
        PlPlayerController.instance?.pause();
      } else {
        if (previous.state == .mini) {
          _start();
          mode.value = .none;
        }
        previous.page?.onMiniDetached();
        _keepDormant(previous, previousDormant!);
      }
    }
    _host = host;
    hosts.add(host);
    layer.notify();
    if (above == null) {
      _updateLayer();
      return;
    }
    final gate = _gate = _DormantGate(host, above);
    _gating.value = true;
    _whenReady(host).then((_) {
      if (!identical(_gate, gate)) {
        return;
      }
      _gate = null;
      _gating.value = false;
      _popAbove(above);
      host.page?.onMiniExpanded();
    });
  }

  void _popAbove(Route<dynamic> route) {
    final navigator = route.navigator;
    if (navigator == null || !route.isActive) {
      return;
    }
    if (route is MiniPlayerWindowRoute) {
      route.leave();
    }
    if (_dormantEntry?.route == route) {
      _dormantEntry!.unregister();
      _dormantEntry = null;
    }
    if (route.isCurrent) {
      navigator.pop();
    } else {
      navigator.removeRoute(route);
    }
  }

  /// 浏览页下方紧邻旧视频记录时，返回键先等该视频的内容到达
  void _syncDormantEntry() {
    final top = _routes.lastOrNull;
    final below = top == null ? null : _routeBelow(top);
    final target =
        top is ModalRoute &&
            top is! MiniPlayerWindowRoute &&
            below is MiniPlayerWindowRoute &&
            below.isDormant
        ? top
        : null;
    final entry = _dormantEntry;
    if (identical(entry?.route, target)) {
      return;
    }
    _dormantEntry = null;
    entry?.unregister();
    if (target != null) {
      _dormantEntry = _DormantPopEntry(
        target,
        onBack: () {
          final dormant = _routeBelow(target);
          if (_gate == null &&
              target.isCurrent &&
              dormant is MiniPlayerWindowRoute &&
              dormant.isDormant) {
            _openDormant(dormant, above: target);
          }
        },
      )..register();
    }
  }

  Future<void> _whenReady(MiniPlayerHostEntry host) => Future(() async {
    await host.attached;
    await host.page?.whenMiniContentReady();
  }).timeout(MiniPlayerMotion.revealTimeout * 2, onTimeout: () {});

  // 状态切换

  void _start() {
    _gate = null;
    _gating.value = false;
    restoring.value = false;
    restoreRect.value = null;
  }

  /// 撤销进行中的展开，小窗回到原位
  void _cancelRestore() {
    restoring.value = false;
    restoreRect.value = null;
    final host = _host;
    final window = host?.presented;
    if (host != null && window != null) {
      host.presented = null;
      window.host = null;
      if (window.isActive) {
        Future.microtask(() => _removeRoute(window));
      }
    }
    _updateLayer();
  }

  /// 立即移除路由，不播放转场
  ///
  /// GetX 在路由被移除后只把当前路由记为其下一层（即使被移除的不是栈顶），
  /// 不更新路由名、参数与依赖归属；这里按实际的栈顶同步，对应
  /// `GetObserver.didPop` 对露出路由的处理，依赖 Get.routing 与
  /// Get.arguments 的页面（如面板注册本地历史、导航去重）才正确
  void _removeRoute(Route<dynamic> route) {
    if (!route.isActive) {
      return;
    }
    route.navigator?.removeRoute(route);
    if (_routes.lastOrNull case final top?) {
      final routing = Get.routing
        ..route = top
        ..args = top.settings.arguments;
      if (top is PageRoute) {
        final name =
            top.settings.name ?? (top is GetPageRoute ? top.routeName : null);
        routing.current = routing.previous = name ?? '';
      }
      syncCurrentRoute();
    }
  }

  // 用户操作

  /// 收起为小窗（下滑、收起按钮）：上方属于详情页的弹窗、面板一并关闭，
  /// 下方紧邻的旧视频记录不再保留，小窗停在最近的普通页面上方
  void collapse(MiniPlayerHost page) {
    final host = _hostOf(page);
    final window = host?.window;
    final navigator = window?.navigator;
    if (host == null ||
        window == null ||
        navigator == null ||
        !identical(host, _host) ||
        host.state != .shown ||
        restoring.value ||
        _gate != null ||
        !page.canEnterMiniPlayer) {
      return;
    }
    for (var below = _routeBelow(window);
        below is MiniPlayerWindowRoute && below.isDormant;
        below = _routeBelow(window)) {
      _removeRoute(below);
    }
    if (identical(host.anchor, window)) {
      host.anchor = null;
    } else {
      host.presented = null;
    }
    window
      ..host = null
      ..leave();
    _collapse(host);
    navigator
      ..popUntil((e) => identical(e, window))
      ..pop();
  }

  /// 从小窗展开：内容到达后在当前页面上方推入窗口，当前页面作为实时背景
  Future<void> restore() async {
    final host = _host;
    if (host == null || !isActive || restoring.value || _gating.value) {
      return;
    }
    _gating.value = true;
    await _whenReady(host);
    _gating.value = false;
    final navigator = Get.key.currentState;
    if (!identical(_host, host) ||
        !isActive ||
        restoring.value ||
        navigator == null) {
      return;
    }
    final window = MiniPlayerWindowRoute(
      host.args,
      host: host,
      presentation: true,
    );
    host.presented = window;
    _expandRestore = true;
    _snapshotRestore = false;
    _liveBackdrop = true;
    restoring.value = true;
    navigator.push(window);
    // 详情页在窗口下方不可见地完成布局与绘制后给出终点
    WidgetsBinding.instance
      ..addPostFrameCallback((_) {
        if (identical(host.presented, window)) {
          _settleRestore(host);
        }
      })
      ..scheduleFrame();
  }

  /// 展开的页面已完全盖住背景，与小窗层停止绘制过渡在同一帧换为实际页面
  void finishRestore() {
    restoring.value = false;
    restoreRect.value = null;
    final host = _host;
    if (host != null && host.state == .shown) {
      host.presented?.reveal();
      host.page?.onMiniExpanded();
    }
    _updateLayer();
  }

  /// 用户在小窗中暂停：进行中的加载完成后同样保持暂停
  Future<void>? pause() {
    shutdownTimerService.holdPendingAutoplay();
    return PlPlayerController.instance?.pause();
  }

  /// 用户在小窗中播放：撤销暂停对进行中加载的影响
  Future<void>? play() {
    shutdownTimerService.releasePendingAutoplay();
    return PlPlayerController.instance?.play();
  }

  /// 关闭小窗：详情页在历史中有位置时留在原处，按离开处理；否则释放
  void close({bool pause = true}) {
    final host = _host;
    if (host == null || !isActive) {
      return;
    }
    _start();
    // 进行中的加载完成后不再自动播放；返回页面时由页面按离开时的状态恢复
    shutdownTimerService.cancelPendingAutoplay();
    mode.value = .none;
    if (host.anchor != null) {
      host
        ..state = .parked
        ..page?.onMiniStopped(resumeOnReturn: !pause);
      _updateLayer();
    } else {
      if (pause) {
        PlPlayerController.instance?.pause();
      }
      _release(host);
    }
  }

  /// 只能在详情页中播放的内容（如互动视频）转入小窗后直接展开
  void showDetail(MiniPlayerHost page) {
    if (isActive && identical(_host?.page, page)) {
      unawaited(restore());
    }
  }
}

class _LayerNotifier extends ChangeNotifier {
  void notify() => notifyListeners();
}

class _DormantGate {
  _DormantGate(this.host, this.above);

  final MiniPlayerHostEntry host;
  final Route<dynamic> above;
}

/// 拦截浏览页的返回，回到下方的旧视频前先等其内容到达
class _DormantPopEntry extends PopEntry<Object?> {
  _DormantPopEntry(this.route, {required this.onBack});

  final ModalRoute<dynamic> route;
  final VoidCallback onBack;

  @override
  final ValueNotifier<bool> canPopNotifier = ValueNotifier(false);

  bool _registered = false;
  bool _removed = false;

  void register() {
    // 路由变化通知期间不修改路由的返回处理
    Future.microtask(() {
      if (!_removed && route.isActive) {
        _registered = true;
        route.registerPopEntry(this);
      }
    });
  }

  void unregister() {
    _removed = true;
    if (_registered) {
      _registered = false;
      if (route.isActive) {
        route.unregisterPopEntry(this);
      }
    }
    Future.microtask(canPopNotifier.dispose);
  }

  @override
  void onPopInvokedWithResult(bool didPop, Object? result) {
    if (!didPop) {
      onBack();
    }
  }
}
