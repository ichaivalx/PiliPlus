import 'dart:async' show Completer, unawaited;
import 'dart:ui' as ui;

import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models/common/video/video_type.dart';
import 'package:PiliPlus/models/video/play/url.dart';
import 'package:PiliPlus/models_new/video/video_detail/data.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/data_source.dart';
import 'package:PiliPlus/plugin/pl_player/models/heart_beat_type.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_repeat.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/services/mini_player/mini_player_media.dart';
import 'package:PiliPlus/services/mini_player/mini_player_policy.dart';
import 'package:PiliPlus/services/mini_player/mini_player_queue.dart';
import 'package:PiliPlus/services/mini_player/mini_player_route.dart';
import 'package:PiliPlus/services/mini_player/mini_player_source.dart';
import 'package:PiliPlus/services/service_locator.dart';
import 'package:PiliPlus/services/shutdown_timer_service.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/reply_scheme_helper.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

/// 视频详情页提供给小窗的能力
abstract interface class MiniPlayerHost {
  Route<dynamic>? get miniRoute;
  String get miniHeroTag;

  /// 当前页面持有播放器且满足小窗条件
  bool get canEnterMiniPlayer;

  /// 当前内容可交给小窗继续播放（不依赖页面布局，页面销毁时也可用）
  bool get canHandOffToMini;

  /// 播放器在页面中的位置，尚未完成布局时为 null
  Rect? get miniPlayerRect;

  /// 缩小时页面淡出所用的截图
  ui.Image? captureMiniSnapshot();
  String get miniTitle;
  String get miniCover;
  Map<String, dynamic> get miniArgs;
  PlayUrlModel get miniPlayUrl;

  /// 页面当前的播放列表，小窗播完后按同样的顺序续播；可能发起请求
  MiniPlayerQueue createMiniQueue();

  /// 页面被内容页覆盖，播放转入小窗
  void onMiniCovered();

  /// 页面不再拥有播放内容
  void onMiniDetached();

  /// 覆盖期间会话结束，页面按离开处理
  void onMiniStopped({required bool resumeOnReturn});

  /// 页面重新成为最上层的页面，未在展示播放器时重新获取
  void onMiniRevealed();
}

enum MiniPlayerMode {
  none,

  /// 详情页仍在栈中，被内容页覆盖
  covered,

  /// 无宿主页面，由会话持有播放器
  headless,
}

final miniPlayerSession = MiniPlayerSession._();

class MiniPlayerSession with WidgetsBindingObserver {
  MiniPlayerSession._() {
    // 小窗存在期间不自动进入系统画中画
    mode.listen((_) => PlPlayerController.instance?.updateAutoEnterPip());
  }

  static const _ownerTag = 'miniPlayer';

  final Rx<MiniPlayerMode> mode = MiniPlayerMode.none.obs;
  final RxBool loading = false.obs;

  /// 恢复为详情页的动画目标
  final RxBool restoring = false.obs;
  final Rxn<Rect> restoreRect = Rxn<Rect>();
  Rect? enterRect;
  ui.Image? _enterSnapshot;

  final Set<MiniPlayerHost> _hosts = {};
  final List<Route<dynamic>> _routes = [];
  MiniPlayerHost? _host;
  PlPlayerController? _player;
  Map<String, dynamic> _args = const {};
  MiniPlayerQueue? _queue;
  PlayUrlModel? _playUrl;
  final RxString _title = ''.obs;
  final RxString _cover = ''.obs;
  String? _restoreTag;
  _Handover? _handover;
  int _epoch = 0;
  bool _settling = false;
  Future<void>? _switching;
  late final _media = MiniPlayerMedia(_ownerTag, onPlay: play, onPause: pause);

  /// 加载期间请求恢复详情页，加载结束后执行
  bool _restorePending = false;

  bool get isActive => mode.value != .none;
  bool get isCovered => mode.value == .covered;
  bool get isHeadless => mode.value == .headless;

  String get title => _host?.miniTitle ?? _title.value;
  String get cover => _host?.miniCover ?? _cover.value;

  bool covers(MiniPlayerHost host) => isCovered && identical(_host, host);

  bool isRestoreTarget(String heroTag) => _restoreTag == heroTag;

  Map<String, dynamic> get _content => _host?.miniArgs ?? _args;

  void attach(MiniPlayerHost host) => _hosts.add(host);

  void detach(MiniPlayerHost host) {
    _hosts.remove(host);
    if (identical(_handover?.host, host)) {
      _handover = null;
    }
    if (_player?.isCloseAll ?? false) {
      // 返回主页时播放器已被整体销毁
      _abandon();
      return;
    }
    if (covers(host)) {
      _takeOverCovered(host);
    } else if (isRestoreTarget(host.miniHeroTag)) {
      _cancelRestore();
    }
    if (isHeadless) {
      // 页面销毁时会把系统媒体状态置为暂停
      Future.microtask(_media.syncState);
    }
  }

  /// 返回 false 表示播放器尚未完成布局，需稍后重试
  bool reportRestoreRect(MiniPlayerHost host) {
    if (!restoring.value || (isActive && !isRestoreTarget(host.miniHeroTag))) {
      return true;
    }
    final rect = host.miniPlayerRect;
    if (rect == null) {
      return false;
    }
    restoreRect.value = rect;
    return true;
  }

  /// 缩小时的页面截图，由小窗取走并负责释放
  ui.Image? takeEnterSnapshot() {
    final snapshot = _enterSnapshot;
    _enterSnapshot = null;
    return snapshot;
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

  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.add(route);
    _onPush(route);
  }

  void _onPush(Route<dynamic> route) {
    switch (MiniPlayerPolicy.classify(route)) {
      case .overlay:
        return;
      case .video:
        final args = route.settings.arguments;
        if (_restoreTag != null &&
            args is Map &&
            args['heroTag'] == _restoreTag) {
          return;
        }
        close(pause: false);
      case .exclusive:
        close(pause: false);
      case .content:
        if (isActive) {
          return;
        }
        final page = _topPage(below: route);
        final host = page == null ? null : _hostOf(page);
        if (host != null &&
            host.canEnterMiniPlayer &&
            (PlPlayerController.instance?.playerStatus.isPlaying ?? false)) {
          _enterCovered(host);
        }
    }
  }

  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    _onReveal();
    _scheduleSettle();
    _revealHost();
  }

  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    _onReveal();
    _scheduleSettle();
    _revealHost();
  }

  /// 隔着弹窗等非页面路由时 RouteAware 不会通知，由此补充
  void _revealHost() {
    if (_topPage() case final page?) {
      _hostOf(page)?.onMiniRevealed();
    }
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

  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final index = oldRoute == null ? -1 : _routes.indexOf(oldRoute);
    if (newRoute != null) {
      if (index == -1) {
        _routes.add(newRoute);
      } else {
        _routes[index] = newRoute;
      }
      _onPush(newRoute);
    } else if (index != -1) {
      _routes.removeAt(index);
    }
    _scheduleSettle();
  }

  MiniPlayerHost? _hostOf(Route<dynamic> route) {
    for (final host in _hosts) {
      if (host.miniRoute == route) {
        return host;
      }
    }
    return null;
  }

  void _scheduleSettle() {
    if (_settling || !isCovered) {
      return;
    }
    _settling = true;
    Future.microtask(() {
      _settling = false;
      final host = _host;
      if (!isCovered || host == null) {
        return;
      }
      final route = host.miniRoute;
      if (route == null || !_routes.contains(route)) {
        _takeOverCovered(host);
      } else if (identical(_topPage(), route)) {
        restoring.value = true;
        restoreRect.value = host.miniPlayerRect;
        _host = null;
        mode.value = .none;
      }
    });
  }

  // 状态切换

  void _start() {
    _epoch++;
    _restorePending = false;
    loading.value = false;
    restoring.value = false;
    restoreRect.value = null;
    _restoreTag = null;
  }

  void _enterCovered(MiniPlayerHost host) {
    _start();
    enterRect = host.miniPlayerRect;
    _host = host;
    mode.value = .covered;
    host.onMiniCovered();
  }

  void _becomeHeadless(MiniPlayerHost host) {
    if (PlPlayerController.instance == null) {
      _host = null;
      mode.value = .none;
      return;
    }
    _args = host.miniArgs;
    _queue = host.createMiniQueue();
    _playUrl = host.miniPlayUrl;
    _title.value = host.miniTitle;
    _cover.value = host.miniCover;
    _host = null;
    if (_player == null) {
      _player = PlPlayerController.getInstance()
        ..addStatusLister(_onPlayerStatus);
      _media.takeControls();
      WidgetsBinding.instance.addObserver(this);
    }
    PlPlayerController.setPlayCallBack(
      play,
      playOwner: (tag: _ownerTag, type: null),
    );
    _updateMediaItem();
    mode.value = .headless;
  }

  /// 覆盖中的宿主页面离开栈：内容可继续时转入无宿主，否则结束会话
  void _takeOverCovered(MiniPlayerHost host) {
    if (host.canHandOffToMini) {
      _becomeHeadless(host);
      Future.microtask(_removeVideoRoutes);
    } else {
      _start();
      _host = null;
      shutdownTimerService.cancelPendingAutoplay();
      mode.value = .none;
    }
  }

  /// 小窗会话期间，栈中不保留与小窗内容不同的详情页
  void _removeVideoRoutes({MiniPlayerHost? except}) {
    if (!isHeadless) {
      return;
    }
    for (final host in _hosts.toList()) {
      if (identical(host, except) || isRestoreTarget(host.miniHeroTag)) {
        continue;
      }
      if (host.miniRoute case final route? when route.isActive) {
        _removeRoute(route);
      }
    }
  }

  /// GetX 在路由被移除后把当前路由记为其下一层，即使被移除的不是栈顶；
  /// 这里改回实际的栈顶，依赖 Get.routing 的页面（如面板注册本地历史）才正确
  void _removeRoute(Route<dynamic> route) {
    route.navigator?.removeRoute(route);
    if (_routes.lastOrNull case final top?) {
      Get.routing.route = top;
    }
  }

  /// 无宿主时由会话处理进入后台，回到前台时由播放器恢复
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_player case final player? when player.pausesInBackground) {
      player.pauseForBackground();
    }
    if (state == .resumed && !loading.value) {
      _runPendingRestore();
    }
  }

  /// 恢复详情页需要渲染帧，后台期间保持延后
  void _runPendingRestore() {
    if (_restorePending &&
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      _restorePending = false;
      restore();
    }
  }

  void _onPlayerStatus(PlayerStatus status) {
    // 恢复中的详情页即将接管
    if (!status.isCompleted || _restoreTag != null) {
      return;
    }
    final player = _player!;
    if (shutdownTimerService.isWaiting) {
      // 同时阻止正在切换的视频自动播放
      shutdownTimerService.handleWaiting();
    } else if (loading.value) {
      // 切换中播完的是旧视频，不再续播
      return;
    } else if (player.isSingleCycle) {
      player.play(repeat: true);
    } else if (player.effectivePlayRepeat != PlayRepeat.pause) {
      unawaited(_playNext(player));
    }
  }

  /// 对应详情页播放完成时调用的 `UgcIntroController.nextPlay`
  Future<void> _playNext(PlPlayerController player) async {
    final queue = _queue;
    final args = _args;
    if (queue == null || args['cid'] is! int) {
      return;
    }
    final epoch = _epoch;
    // 获取下一项期间同样视为加载中；定时关闭到期时不再自动播放
    loading.value = true;
    final load = shutdownTimerService.beginLoad();
    try {
      final next = await queue.next(
        args,
        repeat: player.effectivePlayRepeat,
        showRelated: player.showRelatedVideo,
      );
      if (epoch != _epoch ||
          !isHeadless ||
          _restoreTag != null ||
          !identical(_player, player)) {
        return;
      }
      switch (next) {
        case MiniPlayerReplay():
          if (shutdownTimerService.canAutoplay(load)) {
            player.play(repeat: true);
          }
        case MiniPlayerSwitch(args: final nextArgs, :final inList):
          await _replace(nextArgs, queue: inList ? queue : null, load: load);
        case null:
      }
    } finally {
      shutdownTimerService.endLoad(load);
      _endLoading(epoch);
    }
  }

  /// 本次加载仍是最新的选择时结束加载状态，并执行加载期间请求的操作
  void _endLoading(int epoch) {
    if (epoch != _epoch) {
      return;
    }
    loading.value = false;
    if (_queue?.detail case final detail?) {
      _exitIfInteractive(detail);
    }
    _runPendingRestore();
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

  void _updateMediaItem() => _media.updateItem(
    cid: _args['cid'],
    title: _title.value,
    cover: _cover.value,
    timeLength: _playUrl?.timeLength,
  );

  void _release() {
    _player
      ?..removeStatusLister(_onPlayerStatus)
      ..dispose();
    _player = null;
    _queue = null;
    WidgetsBinding.instance.removeObserver(this);
    _media.restoreControls();
    videoPlayerServiceHandler?.onVideoDetailDispose(_ownerTag);
  }

  /// 播放器已被外部销毁，直接结束会话
  void _abandon() {
    _start();
    _host = null;
    _player?.removeStatusLister(_onPlayerStatus);
    _player = null;
    _queue = null;
    WidgetsBinding.instance.removeObserver(this);
    _media.restoreControls();
    mode.value = .none;
  }

  // 用户操作

  void shrink(MiniPlayerHost host) {
    if (isActive || !host.canEnterMiniPlayer) {
      return;
    }
    _start();
    enterRect = host.miniPlayerRect;
    _enterSnapshot?.dispose();
    _enterSnapshot = host.captureMiniSnapshot();
    host.onMiniDetached();
    _becomeHeadless(host);
    // 先移除其他详情页，避免出栈时露出的详情页重新获取播放器
    _removeVideoRoutes(except: host);
    _dismissHostRoute(host);
  }

  /// 隐藏详情页，改由截图淡出，下方页面照常播放返回转场；
  /// 按实例出栈，页面内面板等本地历史一并弹出
  void _dismissHostRoute(MiniPlayerHost host) {
    final route = host.miniRoute;
    final navigator = route?.navigator;
    if (route == null || navigator == null || !route.isActive) {
      return;
    }
    if (route is ModalRoute) {
      route.offstage = true;
    }
    if (route.isCurrent) {
      navigator.popUntil((e) => !identical(e, route));
    } else {
      _removeRoute(route);
    }
  }

  void restore() {
    if (restoring.value) {
      return;
    }
    if (loading.value) {
      _restorePending = true;
      return;
    }
    switch (mode.value) {
      case .none:
        return;
      case .covered:
        final host = _host!;
        final route = host.miniRoute;
        restoring.value = true;
        restoreRect.value = host.miniPlayerRect;
        Future.microtask(
          () => route?.navigator?.popUntil((e) => e == route),
        );
      case .headless:
        final cid = _args['cid'];
        final tag = _restoreTag = Utils.makeHeroTag(cid);
        restoring.value = true;
        final args = <String, dynamic>{
          ..._args,
          'heroTag': tag,
          'progress': ?_player?.positionInMilliseconds,
        }
          ..remove(rootRpIdKey)
          ..remove(secondRpIdKey);
        Future.microtask(
          () => Get.key.currentState?.push(MiniPlayerRestoreRoute(args)),
        );
    }
  }

  void finishRestore() {
    restoring.value = false;
    restoreRect.value = null;
  }

  void _cancelRestore() {
    _restoreTag = null;
    restoring.value = false;
    restoreRect.value = null;
    if (isHeadless) {
      PlPlayerController.setPlayCallBack(
        play,
        playOwner: (tag: _ownerTag, type: null),
      );
    }
  }

  /// 恢复的详情页初始化时立即接管播放器，之后页面按普通详情页处理；
  /// 返回小窗已获取的视频详情供页面先行展示
  VideoDetailData? handOver(MiniPlayerHost host) {
    final playUrl = _playUrl;
    if (!isHeadless || !isRestoreTarget(host.miniHeroTag) || playUrl == null) {
      return null;
    }
    final detail = _queue?.detail;
    _handover = (
      host: host,
      bvid: _args['bvid'],
      cid: _args['cid'],
      playUrl: playUrl,
    );
    _restoreTag = null;
    _release();
    mode.value = .none;
    _media.syncState();
    return detail;
  }

  /// 接管页面复用正在播放的资源
  LoadingState<PlayUrlModel>? playUrlFor(int cid) => switch (_handover) {
    final handover? when handover.cid == cid => Success(handover.playUrl),
    _ => null,
  };

  /// 接管页面首次设置播放源时保留正在播放的内容
  bool adopt({String? bvid, int? cid}) {
    if (_handover case final handover?
        when handover.bvid == bvid && handover.cid == cid) {
      _handover = null;
      return true;
    }
    return false;
  }

  void close({bool pause = true}) {
    if (!isActive) {
      return;
    }
    final host = _host;
    _start();
    // 进行中的加载完成后不再自动播放；返回页面时由页面按离开时的状态恢复
    shutdownTimerService.cancelPendingAutoplay();
    if (host != null) {
      _host = null;
      mode.value = .none;
      host.onMiniStopped(resumeOnReturn: !pause);
    } else {
      final player = _player!;
      player.makeHeartBeat(
        player.position.value,
        type: HeartBeatType.status,
        isManual: true,
      );
      if (pause) {
        player.pause();
      }
      if (PlPlayerController.playOwner?.tag == _ownerTag) {
        PlPlayerController.setPlayCallBack(null);
      }
      mode.value = .none;
      _release();
    }
  }

  /// 小窗存在时打开视频：相同视频恢复，其他 UGC 视频在小窗内切换
  bool interceptVideoPage(Map args, {required bool off}) {
    if (!isActive) {
      return false;
    }
    if (off || !MiniPlayerPolicy.canLoadInMini(args) || _hasIntent(args)) {
      close();
      return false;
    }
    final content = _content;
    if (content['bvid'] == args['bvid'] && content['cid'] == args['cid']) {
      if (!_isSameList(args, content)) {
        close();
        return false;
      }
      if (loading.value) {
        _keepCurrent();
      }
      restore();
      return true;
    }
    if (restoring.value) {
      close();
      return false;
    }
    unawaited(_replace(Map<String, dynamic>.from(args)));
    return true;
  }

  /// 定位评论、指定进度的请求按普通方式打开详情页
  static bool _hasIntent(Map args) =>
      args[rootRpIdKey] != null ||
      args[secondRpIdKey] != null ||
      args['progress'] != null;

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

  /// 切换进行中再次选择当前视频：最后一次选择生效
  void _keepCurrent() {
    final player = _player!;
    if (_switching == null) {
      // 尚未开始切换播放源，当前视频仍在播放
      _epoch++;
      loading.value = false;
    } else {
      unawaited(
        _replace(
          {..._args, 'progress': player.positionInMilliseconds},
          queue: _queue,
        ),
      );
    }
  }

  /// 互动视频需在详情页播放；有更新的选择在加载时由其结束后再判断
  void _exitIfInteractive(VideoDetailData detail) {
    if (!isHeadless ||
        loading.value ||
        detail.bvid != _args['bvid'] ||
        detail.rights?.isSteinGate != 1) {
      return;
    }
    final args = _args;
    close();
    PageUtils.toDupNamed(MiniPlayerPolicy.videoRoute, arguments: args);
  }

  /// 未提供 [queue] 时按新视频的参数获取播放列表，与开始播放并行
  Future<void> _replace(
    Map<String, dynamic> args, {
    MiniPlayerQueue? queue,
    ShutdownLoad? load,
  }) async {
    queue ??= MiniPlayerQueue.fetch(args);
    if (_host case final host?) {
      _start();
      host.onMiniDetached();
      _becomeHeadless(host);
      Future.microtask(_removeVideoRoutes);
    } else {
      _epoch++;
      final player = _player!;
      player.makeHeartBeat(
        player.position.value,
        type: HeartBeatType.status,
        isManual: true,
      );
    }
    final epoch = _epoch;
    final player = _player;
    if (player == null) {
      return;
    }
    loading.value = true;
    // 调用方未提供时自行创建并负责结束
    final ownLoad = load == null ? shutdownTimerService.beginLoad() : null;
    try {
      await _switchTo(args, queue, player, epoch, load ?? ownLoad!);
    } finally {
      if (ownLoad != null) {
        shutdownTimerService.endLoad(ownLoad);
      }
      _endLoading(epoch);
    }
  }

  Future<void> _switchTo(
    Map<String, dynamic> args,
    MiniPlayerQueue queue,
    PlPlayerController player,
    int epoch,
    ShutdownLoad load,
  ) async {
    bool isOwner() => isHeadless && identical(_player, player);

    final aid = args['aid'] as int;
    final bvid = args['bvid'] as String;
    final cid = args['cid'] as int;
    final result = await MiniPlayerSourceResolver.resolve(
      player,
      aid: aid,
      bvid: bvid,
      cid: cid,
    );
    // 串行切换，播放器与会话信息始终对应同一个视频
    for (var f = _switching; f != null; f = _switching) {
      await f;
    }
    if (epoch != _epoch || !isOwner()) {
      return;
    }
    switch (result) {
      case Success(:final response?):
        final completer = Completer<void>();
        _switching = completer.future;
        try {
          final data = response.data;
          final progress =
              args.remove('progress') as int? ?? data.lastPlayTime;
          final video = response.video;
          final isVertical = args['isVertical'] ??=
              (video.height ?? 0) > (video.width ?? 0);
          await player.setDataSource(
            NetworkSource(
              videoSource: response.videoUrl,
              audioSource: response.audioUrl,
            ),
            seekTo: progress > 0 ? Duration(milliseconds: progress) : null,
            duration: data.timeLength == null
                ? null
                : Duration(milliseconds: data.timeLength!),
            isVertical: isVertical,
            aid: aid,
            bvid: bvid,
            cid: cid,
            videoType: VideoType.ugc,
            width: video.width,
            height: video.height,
            volume: data.volume,
            load: load,
          );
          // 会话信息始终对应实际加载的播放源，即使之后又有新的选择
          if (isOwner()) {
            _args = args;
            _queue = queue
              ..select(bvid)
              ..onDetail = (detail) {
                if (identical(_queue, queue)) {
                  _exitIfInteractive(detail);
                }
              };
            _playUrl = data;
            _title.value = args['title'] ?? '';
            _cover.value = args['cover'] ?? '';
            _updateMediaItem();
          }
        } finally {
          _switching = null;
          completer.complete();
        }
      case Success():
        close();
        PageUtils.toDupNamed(MiniPlayerPolicy.videoRoute, arguments: args);
      case final Error error:
        error.toast();
      case Loading():
        break;
    }
  }
}

typedef _Handover = ({
  MiniPlayerHost host,
  String? bvid,
  int? cid,
  PlayUrlModel playUrl,
});
