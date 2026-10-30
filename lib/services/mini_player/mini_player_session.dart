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

  /// 收起时代替页面绘制的截图，立即返回，在下一帧绘制前完成光栅化
  ui.Image? captureMiniSnapshot();

  /// 展开时代替页面绘制的截图，光栅化完成后返回；页面需已绘制
  Future<ui.Image?> renderMiniSnapshot();
  String get miniTitle;
  String get miniCover;

  /// 当前播放的内容，用于判断打开的是否为同一视频，也是保留为旧视频记录
  /// 时重新打开所用的参数
  Map<String, dynamic> get miniArgs;

  /// 播放器尚未开始播放当前内容
  bool get isMiniPlayerLoading;

  /// 离开时的播放进度（毫秒，未知或已播完时为 null）及播放状态，保留为
  /// 旧视频记录后据此恢复
  ({int? progress, MiniPlayerResume resume}) get miniPlayback;

  /// 正在返回主页（关闭所有页面），播放器已整体销毁
  bool get isClosingAll;

  /// 各区域所需的内容到达（或等待超时）后完成
  Future<void> whenMiniContentReady();

  /// 收起为小窗，页面不再显示；返回系统栏等的变化，收起的过渡在其后开始
  Future<void>? onMiniCollapsed();

  /// 从小窗展开，页面重新显示
  void onMiniExpanded();

  /// 页面获得焦点：恢复页面中上次的焦点，没有时交给播放器的快捷键
  void focusMiniPlayer();

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

/// 从小窗展开时详情页所处的阶段，由小窗层随过渡推进
enum MiniRestoreStage {
  /// 不上屏地绘制，截取过渡所用的画面
  capture,

  /// 以截图过渡，详情页不绘制
  motion,

  /// 过渡接近终点，详情页在截图下方提前显示，交接时不再首次绘制
  warm,
}

/// 详情页离开时的播放状态，回到该视频时按此恢复
enum MiniPlayerResume {
  /// 在播放，或加载完成后会自动播放
  playing,

  /// 已暂停
  paused,

  /// 尚未开始播放，等待用户开始（不自动播放时）
  idle,
}

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
  Future<void>? _enterReady;

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

  /// 展开中详情页的阶段，展开开始截图前为 null
  MiniRestoreStage? _restoreStage;
  set restoreStage(MiniRestoreStage? value) {
    if (_restoreStage != value) {
      _restoreStage = value;
      _updateLayer();
    }
  }

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

  /// 展开的终点页面的截图，光栅化完成后返回，由小窗层取走并负责释放
  Future<ui.Image?> captureRestorePage() async =>
      await _host?.page?.renderMiniSnapshot();

  /// 收起时的页面截图，由小窗取走并负责释放
  ui.Image? takeEnterSnapshot() {
    final snapshot = _enterSnapshot;
    _enterSnapshot = null;
    return snapshot;
  }

  /// 收起时系统栏等的变化，由小窗取走，在其后开始过渡
  Future<void>? takeEnterReady() {
    final ready = _enterReady;
    _enterReady = null;
    return ready;
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
    if (page.isClosingAll && hosts.isNotEmpty) {
      // 返回主页时播放器已被整体销毁，页面移除期间不修改宿主层
      Future.microtask(() {
        for (final host in hosts.toList()) {
          _release(host);
        }
      });
    }
  }

  /// 宿主中的页面在构建、布局之外（如异步回调中）创建的控制器属于该页面，
  /// 随宿主释放
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

  /// 宿主中的页面构建与布局：创建的依赖归属该详情页，读取的路由参数为其
  /// 参数
  void runInHost(MiniPlayerHostEntry host, VoidCallback body) {
    final routing = Get.routing;
    final args = routing.args;
    routing.args = host.args;
    RouterReportManager.reportCurrentRoute(host.route);
    try {
      body();
    } finally {
      routing.args = args;
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
        if (!_hasIntent(args) &&
            args['progress'] == null &&
            _isSameList(args, content)) {
          unawaited(restore());
          return true;
        }
        // 换列表、定位评论或指定进度时按普通方式打开；未指定进度时从小窗的
        // 当前进度继续，已播完时按入口参数
        if (PlPlayerController.instance case final player?
            when args['progress'] == null &&
                !player.playerStatus.isCompleted) {
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
    final dormant = _dormantOf(host);
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

  /// 重新打开旧视频所用的参数与播放状态：从离开时的进度与状态继续，不再
  /// 定位评论；页面尚未接入时沿用打开时的参数
  MiniPlayerDormant _dormantOf(MiniPlayerHostEntry host) {
    final page = host.page;
    final args = <String, dynamic>{...(page?.miniArgs ?? host.args)}
      ..remove(rootRpIdKey)
      ..remove(secondRpIdKey);
    if (page == null) {
      return MiniPlayerDormant(args, resume: host.resume);
    }
    final playback = page.miniPlayback;
    if (playback.progress case final progress?) {
      args['progress'] = progress;
    } else {
      args.remove('progress');
    }
    return MiniPlayerDormant(args, resume: playback.resume);
  }

  /// 释放宿主，其所在的位置保留为旧视频记录
  void _keepDormant(MiniPlayerHostEntry host, MiniPlayerDormant dormant) {
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
    final dormant = _dormantOf(previous);
    previous.page?.onMiniDetached();
    final host = MiniPlayerHostEntry(args, hidden: true)..state = .mini;
    _host = host;
    hosts.add(host);
    _keepDormant(previous, dormant);
    _revision.value++;
  }

  void _release(MiniPlayerHostEntry host) {
    if (identical(_gate?.host, host)) {
      _endGate();
    }
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
    if (_gate case final gate? when identical(gate.above, route)) {
      // 上层页面未经等待离开（如连续出栈），上一个视频直接露出
      _endGate();
      if (gate.host case final host?) {
        host.attached.then((_) {
          if (identical(_host, host) && host.state == .shown) {
            host.page?.onMiniExpanded();
          }
        });
      }
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
        _keepDormant(host, window.dormant ?? _dormantOf(host));
      }
    }
  }

  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _track(route);
    _onPush(route);
    _finishTransitions();
    _afterRouteChange();
  }

  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _untrack(route);
    _gateLeavingPage(route);
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
      _finishTransitions();
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

  /// 窗口转场期间其上方推入其他路由（如菜单、弹窗、页面）：宿主无法同时
  /// 位于下方页面之上、新路由之下，窗口的转场直接结束，入场的直接显示，
  /// 离开的直接移除
  void _finishTransitions() {
    final top = _routes.lastOrNull;
    final windows = [
      for (final host in hosts)
        if (host.window case final window?
            when !identical(window, top) &&
                (window.animation?.isAnimating ?? false))
          window,
    ];
    if (windows.isEmpty) {
      return;
    }
    // 路由变化通知期间不修改路由
    Future.microtask(() {
      for (final window in windows) {
        // ignore: invalid_use_of_protected_member
        final controller = window.controller;
        if (controller == null || !controller.isAnimating) {
          continue;
        }
        controller.value = controller.status == .forward
            ? controller.upperBound
            : controller.lowerBound;
      }
    });
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
    _enterReady = page.onMiniCollapsed();
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
    _restoreStage = null;
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

  /// 旧视频记录未经等待直接露出（如直接移除上层页面），立即重新打开；
  /// 同一次路由变化中继续出栈（如逐层返回首页）时不再打开
  void _openExposedDormant() {
    if (_topPage() case final MiniPlayerWindowRoute window
        when window.isDormant && _gate == null) {
      Future.microtask(() {
        if (_gate == null &&
            !_closingAll &&
            window.isDormant &&
            identical(_topPage(), window)) {
          _openDormant(window, gate: null);
        }
      });
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

  /// 各宿主的显示方式及绘制顺序：位于窗口下方且窗口露出时显示；窗口自身
  /// 转场期间位于浏览 Navigator 上方。操作按显示转交，见
  /// [MiniPlayerHostEntry.hitTestThroughWindow]
  ///
  /// 从小窗展开时详情页按 [_restoreStage] 只在截图时绘制、接近终点时提前
  /// 显示；展开、收起期间详情页的动画停止
  void _updateLayer() {
    final top = _routes.lastOrNull;
    final gate = _gate;
    for (final host in hosts) {
      if (gate != null && identical(gate.host, host) && !gate.above.isActive) {
        // 上层页面停在出栈转场开始处，等待期间不显示
        host.updateLayer(visibility: .hidden, ticking: false, z: -1);
        continue;
      }
      final window = host.window;
      final index = window == null ? -1 : _routes.indexOf(window);
      final exposed = index == -1
          ? _leaving.contains(window)
          : _isExposed(index);
      final bool visible;
      var lifted = false;
      switch (host.state) {
        case .shown || .parked || .outgoing:
          visible = exposed;
          lifted =
              host.state == .shown &&
              identical(window, top) &&
              !(window!.animation?.isCompleted ?? true);
        case .mini:
          visible =
              exposed &&
              (restoring.value || (_userGesture?.value ?? false));
        case .closing:
          final animation = window?.animation;
          visible = lifted = animation != null && !animation.isDismissed;
      }
      final restoringHost = restoring.value && identical(host, _host);
      final MiniHostVisibility visibility;
      if (!visible) {
        visibility = .hidden;
      } else if (restoringHost && _expandRestore) {
        visibility = switch (_restoreStage) {
          null || MiniRestoreStage.motion => .hidden,
          MiniRestoreStage.capture => .offscreen,
          MiniRestoreStage.warm => .shown,
        };
      } else {
        visibility = .shown;
      }
      host.updateLayer(
        visibility: visibility,
        ticking: visibility == .shown && !restoringHost,
        z: lifted ? 1 : index - _routes.length - 1,
        // 入场中位于浏览 Navigator 上方，直接响应操作；离开中的不响应
        direct: lifted && host.state == .shown,
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

  /// 返回主页时各页面逐层出栈，不再收起、等待或重新打开旧视频
  bool get _closingAll => hosts.any((e) => e.page?.isClosingAll ?? false);

  /// 显示中的详情页出栈（返回键、Get.back 等），面板已先行关闭：
  /// 下方为旧视频时等其内容到达后回到该视频；可进入小窗时收起；否则关闭
  ///
  /// 只在开始等待时拒绝一次出栈，同一窗口再次出栈（如 popUntil 逐层出栈）
  /// 时不再等待，任何出栈序列都能结束
  bool allowWindowPop(MiniPlayerWindowRoute window) {
    final host = window.host;
    if (host == null) {
      return true;
    }
    if (_closingAll) {
      _endGate();
      if (host.state == .shown) {
        host.state = .closing;
        window.forwardPop = true;
      }
      return true;
    }
    if (!identical(host, _host)) {
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
    if (restoring.value) {
      // 展开动画中直接出栈，按展开已完成处理
      restoring.value = false;
      restoreRect.value = null;
      host.presented?.reveal();
    }
    if (_gate case final gate? when identical(gate.above, window)) {
      // 等待期间再次出栈不再等待，上一个视频直接露出
      _endGate();
    } else if (_routeBelow(window) case final MiniPlayerWindowRoute below
        when _gate == null && below.isDormant) {
      _beginGate(below, above: window);
      return false;
    } else if (host.page?.canEnterMiniPlayer ?? false) {
      if (identical(host.anchor, window)) {
        host.anchor = null;
      } else {
        host.presented = null;
      }
      window
        ..host = null
        ..leave();
      _collapse(host);
      // 窗口直接移除，下方页面不播放返回转场，详情页的截图在其上方收起
      Future.microtask(() => _removeRoute(window));
      return false;
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
      if (next != null && !identical(next, host)) {
        _takeOverWhenAttached(next);
      }
    }
    _updateLayer();
  }

  /// 播放器空出后由延后接管的详情页接管，页面尚未初始化时在其后接管
  void _takeOverWhenAttached(MiniPlayerHostEntry host) {
    host.attached.then((_) {
      if (host.deferPlayer && hosts.contains(host)) {
        host.deferPlayer = false;
        host.page?.takeOverPlayer();
      }
    });
  }

  // 旧视频记录

  /// 回到下方的旧视频，旧视频的内容到达后上层页面再离开：上层为详情页的
  /// 窗口时暂不出栈；上层为已出栈的浏览页时其出栈转场停在开始处。同一次
  /// 出栈中继续出栈（如逐层返回首页）时不再打开
  void _beginGate(
    MiniPlayerWindowRoute dormant, {
    required Route<dynamic> above,
  }) {
    final gate = _gate = _DormantGate(above);
    _gating.value = true;
    Future.microtask(() {
      if (!identical(_gate, gate)) {
        return;
      }
      if (_closingAll ||
          !dormant.isDormant ||
          !(above.isActive || dormant.isCurrent)) {
        _endGate();
        return;
      }
      if (!above.isActive && above is TransitionRoute) {
        // ignore: invalid_use_of_protected_member
        above.controller?.stop();
      }
      _openDormant(dormant, gate: gate);
    });
  }

  /// 结束等待：停住的出栈转场继续
  void _endGate() {
    final gate = _gate;
    _gate = null;
    _gating.value = false;
    if (gate == null) {
      return;
    }
    final above = gate.above;
    if (!above.isActive && above is TransitionRoute) {
      // ignore: invalid_use_of_protected_member
      final controller = above.controller;
      if (controller != null &&
          !controller.isAnimating &&
          !controller.isDismissed) {
        controller.reverse();
      }
    }
    if (gate.host != null) {
      _updateLayer();
    }
  }

  /// 浏览页出栈后下方为旧视频记录（返回键、Get.back 等，未经详情页）：
  /// 浏览页停在出栈转场开始处，旧视频的内容到达后继续
  void _gateLeavingPage(Route<dynamic> route) {
    if (route is MiniPlayerWindowRoute ||
        _gate != null ||
        _closingAll ||
        (route.navigator?.userGestureInProgress ?? false)) {
      return;
    }
    if (_routes.lastOrNull case final MiniPlayerWindowRoute dormant
        when dormant.isDormant) {
      _beginGate(dormant, above: route);
    }
  }

  /// 重新打开旧视频：新的详情页在其记录的位置构建；[gate] 不为 null 时在
  /// 上层页面下方不显示地构建，内容到达后上层页面再出栈。新的详情页在原
  /// 详情页交出播放器后接管，按离开时的播放状态恢复
  void _openDormant(MiniPlayerWindowRoute dormant, {_DormantGate? gate}) {
    final record = dormant.dormant!;
    final above = gate?.above;
    final previous = _host;
    // 接管播放器之前记下离开时的进度
    final previousDormant = previous == null ? null : _dormantOf(previous);
    final shownAbove =
        previous != null &&
        previous.state == .shown &&
        identical(previous.window, above);
    // 记录的位置即为详情页的位置，其路由参数原地更新为新详情页的参数
    final args = dormant.arguments
      ..clear()
      ..addAll(record.args)
      ..['heroTag'] = Utils.makeHeroTag(record.args['cid']);
    final host = MiniPlayerHostEntry(
      args,
      hidden: above != null,
      deferPlayer: true,
      resume: record.resume,
    );
    dormant
      ..dormant = null
      ..host = host;
    host.anchor = dormant;
    if (previous != null) {
      previous.page?.onMiniDetached();
      if (shownAbove) {
        // 显示中的详情页随出栈转场离开后释放，期间保持暂停时的画面
        previous.state = .closing;
      } else {
        if (previous.state == .mini) {
          restoring.value = false;
          restoreRect.value = null;
          mode.value = .none;
        }
        _keepDormant(previous, previousDormant!);
      }
      PlPlayerController.instance?.pause();
    }
    _host = host;
    hosts.add(host);
    layer.notify();
    if (!shownAbove) {
      _takeOverWhenAttached(host);
    }
    if (gate == null) {
      _updateLayer();
      return;
    }
    gate.host = host;
    _whenReady(host).then((_) {
      if (!identical(_gate, gate)) {
        return;
      }
      _endGate();
      if (gate.above.isActive) {
        _popAbove(gate.above);
      }
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

  /// 浏览页下方紧邻旧视频记录时，浏览页自身没有要先关闭的面板等时禁用
  /// 拖动返回，返回键转为出栈，由 [_gateLeavingPage] 等待旧视频
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
      _dormantEntry = _DormantPopEntry(target)..register();
    }
  }

  Future<void> _whenReady(MiniPlayerHostEntry host) => Future(() async {
    await host.attached;
    await host.page?.whenMiniContentReady();
  }).timeout(MiniPlayerMotion.revealTimeout, onTimeout: () {});

  // 状态切换

  void _start() {
    _endGate();
    _restoreStage = null;
    restoring.value = false;
    restoreRect.value = null;
  }

  /// 撤销进行中的展开，小窗回到原位
  void _cancelRestore() {
    _restoreStage = null;
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
    // 窗口直接移除，下方页面不播放返回转场，详情页的截图在其上方收起
    navigator.popUntil((e) => identical(e, window));
    _removeRoute(window);
  }

  /// 从小窗展开：内容到达后在当前页面上方推入窗口。背景为当前画面的截图，
  /// 页面层在展开期间不上屏；当前页面含 platform view（截图不含其内容）
  /// 时以实时页面为背景
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
    final live = _showsPlatformView;
    final window = MiniPlayerWindowRoute(
      host.args,
      host: host,
      presentation: true,
      overBackdrop: live,
    );
    host.presented = window;
    _expandRestore = true;
    _snapshotRestore = !live;
    _liveBackdrop = live;
    _restoreStage = null;
    // 小窗层在此截取背景，其后推入的窗口遮住下方页面
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

  /// 当前显示的页面（最上层的不透明页面及其上方的路由）含 platform view
  bool get _showsPlatformView {
    final page = _topPage();
    final index = page == null ? 0 : _routes.indexOf(page);
    return _routes.skip(index).any(MiniPlayerPolicy.hasPlatformView);
  }

  /// 展开的页面已完全盖住背景，与小窗层停止绘制过渡在同一帧换为实际页面；
  /// 系统栏、亮度与焦点在交接后的下一帧恢复，不与交接落在同一帧
  void finishRestore() {
    _restoreStage = null;
    restoring.value = false;
    restoreRect.value = null;
    final host = _host;
    if (host != null && host.state == .shown) {
      host.presented?.reveal();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (identical(_host, host) && host.state == .shown && !isActive) {
          host.page
            ?..onMiniExpanded()
            ..focusMiniPlayer();
        }
      });
    }
    _updateLayer();
  }

  /// 窗口自身获得焦点（如其上方的弹窗、菜单关闭后焦点回到窗口）：焦点
  /// 交给所呈现的详情页；详情页随路由变化重新显示时在其构建后交给
  void focusWindow(MiniPlayerWindowRoute window) {
    WidgetsBinding.instance
      ..addPostFrameCallback((_) {
        final host = window.host;
        if (window.focusScopeNode.hasPrimaryFocus &&
            host != null &&
            host.state == .shown &&
            host.shown &&
            !(restoring.value && identical(host, _host))) {
          host.page?.focusMiniPlayer();
        }
      })
      ..scheduleFrame();
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
  _DormantGate(this.above);

  /// 上层的详情页窗口（尚未出栈），或已出栈、转场停住的浏览页
  final Route<dynamic> above;

  /// 重新打开的详情页，开始等待后的微任务中创建
  MiniPlayerHostEntry? host;
}

/// 浏览页的返回处理：浏览页的返回会离开该页面（没有先关闭的面板、其他
/// PopScope 也允许）时不响应返回与拖动返回，返回键转为直接出栈；出栈时由
/// 会话等待下方的旧视频。只在返回时判断，不影响浏览页自身返回处理的顺序
class _DormantPopEntry extends PopEntry<Object?> {
  _DormantPopEntry(this.route);

  final ModalRoute<dynamic> route;

  bool _probing = false;

  @override
  late final ValueListenable<bool> canPopNotifier = _CanPop(this);

  bool get _canPop => _probing || route.willHandlePopInternally;

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
  }

  @override
  void onPopInvokedWithResult(bool didPop, Object? result) {
    if (didPop) {
      return;
    }
    // 除本记录外浏览页允许返回时才出栈
    _probing = true;
    final disposition = route.popDisposition;
    _probing = false;
    if (disposition == RoutePopDisposition.pop &&
        !route.willHandlePopInternally) {
      Future.microtask(() {
        if (!_removed && route.isCurrent) {
          route.navigator?.pop(result);
        }
      });
    }
  }
}

class _CanPop implements ValueListenable<bool> {
  _CanPop(this.entry);

  final _DormantPopEntry entry;

  @override
  bool get value => entry._canPop;

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
}
