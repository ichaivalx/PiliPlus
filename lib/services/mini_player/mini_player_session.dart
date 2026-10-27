import 'dart:async' show unawaited;

import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models/common/video/video_type.dart';
import 'package:PiliPlus/models/video/play/url.dart';
import 'package:PiliPlus/models_new/video/video_detail/page.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/data_source.dart';
import 'package:PiliPlus/plugin/pl_player/models/heart_beat_type.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/services/mini_player/mini_player_policy.dart';
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
  Rect? get miniPlayerRect;
  String get miniTitle;
  String get miniCover;
  Map<String, dynamic> get miniArgs;
  PlayUrlModel get miniPlayUrl;

  /// 页面被内容页覆盖，播放转入小窗
  void onMiniCovered();

  /// 页面不再拥有播放内容
  void onMiniDetached();

  /// 覆盖期间会话结束，页面按离开处理
  void onMiniStopped({required bool resumeOnReturn});

  /// 非 GetPageRoute 出栈后页面重新可见
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

class MiniPlayerSession {
  MiniPlayerSession._();

  static const _ownerTag = 'miniPlayer';

  final Rx<MiniPlayerMode> mode = MiniPlayerMode.none.obs;
  final RxBool loading = false.obs;

  /// 恢复为详情页的动画目标
  final RxBool restoring = false.obs;
  final Rxn<Rect> restoreRect = Rxn<Rect>();
  Rect? enterRect;

  final Set<MiniPlayerHost> _hosts = {};
  final List<Route<dynamic>> _routes = [];
  MiniPlayerHost? _host;
  PlPlayerController? _player;
  Map<String, dynamic> _args = const {};
  PlayUrlModel? _playUrl;
  final RxString _title = ''.obs;
  final RxString _cover = ''.obs;
  String? _restoreTag;
  int _epoch = 0;
  bool _settling = false;

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
    if (covers(host)) {
      _becomeHeadless(host);
      Future.microtask(_removeVideoRoutes);
    } else if (isRestoreTarget(host.miniHeroTag)) {
      _cancelRestore();
    }
  }

  void reportRestoreRect(MiniPlayerHost host) {
    if (restoring.value && (isRestoreTarget(host.miniHeroTag) || !isActive)) {
      restoreRect.value = host.miniPlayerRect;
    }
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
    if (route is PageRoute && route is! GetPageRoute) {
      if (_topPage() case final page?) {
        _hostOf(page)?.onMiniRevealed();
      }
    }
    _scheduleSettle();
  }

  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    _scheduleSettle();
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
        _becomeHeadless(host);
        _removeVideoRoutes();
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
    _playUrl = host.miniPlayUrl;
    _title.value = host.miniTitle;
    _cover.value = host.miniCover;
    _host = null;
    final player = _player ??= PlPlayerController.getInstance()
      ..addStatusLister(_onPlayerStatus);
    PlPlayerController.setPlayCallBack(
      player.play,
      playOwner: (tag: _ownerTag, type: null),
    );
    _updateMediaItem();
    mode.value = .headless;
  }

  /// 小窗会话期间，栈中不保留与小窗内容不同的详情页
  void _removeVideoRoutes() {
    if (!isHeadless) {
      return;
    }
    for (final host in _hosts.toList()) {
      if (isRestoreTarget(host.miniHeroTag)) {
        continue;
      }
      final route = host.miniRoute;
      if (route != null && route.isActive) {
        route.navigator?.removeRoute(route);
      }
    }
  }

  void _onPlayerStatus(PlayerStatus status) {
    if (!status.isCompleted) {
      return;
    }
    if (shutdownTimerService.isWaiting) {
      shutdownTimerService.handleWaiting();
    } else if (_player?.isSingleCycle ?? false) {
      _player!.play(repeat: true);
    }
  }

  void _updateMediaItem() {
    final handler = videoPlayerServiceHandler;
    final cid = _args['cid'];
    if (handler == null || cid is! int) {
      return;
    }
    handler
      ..onVideoDetailDispose(_ownerTag)
      ..onVideoDetailChange(
        Part(
          cid: cid,
          part: _title.value,
          duration: (_playUrl?.timeLength ?? 0) ~/ 1000,
        ),
        cid,
        _ownerTag,
        cover: _cover.value,
      );
  }

  void _release() {
    _player
      ?..removeStatusLister(_onPlayerStatus)
      ..dispose();
    _player = null;
    videoPlayerServiceHandler?.onVideoDetailDispose(_ownerTag);
  }

  // 用户操作

  void shrink(MiniPlayerHost host) {
    if (isActive || !host.canEnterMiniPlayer) {
      return;
    }
    _start();
    enterRect = host.miniPlayerRect;
    host.onMiniDetached();
    _becomeHeadless(host);
    Future.microtask(() {
      if (isHeadless) {
        host.miniRoute?.navigator?.popUntil(
          (route) => route.isFirst || !MiniPlayerPolicy.isVideoRoute(route),
        );
        _removeVideoRoutes();
      }
    });
  }

  void restore() {
    if (loading.value || restoring.value) {
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
          () => PageUtils.toDupNamed(
            MiniPlayerPolicy.videoRoute,
            arguments: args,
          ),
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
        _player!.play,
        playOwner: (tag: _ownerTag, type: null),
      );
    }
  }

  /// 恢复的详情页直接接管正在播放的资源
  LoadingState<PlayUrlModel>? playUrlFor(int cid) =>
      _restoreTag != null && _args['cid'] == cid && _playUrl != null
      ? Success(_playUrl!)
      : null;

  bool adopt({String? bvid, int? cid}) {
    if (!isHeadless ||
        _restoreTag == null ||
        _args['bvid'] != bvid ||
        _args['cid'] != cid) {
      return false;
    }
    _restoreTag = null;
    _release();
    mode.value = .none;
    return true;
  }

  void close({bool pause = true}) {
    if (!isActive) {
      return;
    }
    final current = mode.value;
    _start();
    switch (current) {
      case .none:
        return;
      case .covered:
        final host = _host!;
        _host = null;
        mode.value = .none;
        host.onMiniStopped(resumeOnReturn: !pause);
      case .headless:
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
    final content = _content;
    if (content['bvid'] == args['bvid'] && content['cid'] == args['cid']) {
      if (isHeadless) {
        _args = {
          ...args,
          'title': ?content['title'],
          'cover': ?content['cover'],
        };
      }
      restore();
      return true;
    }
    if (off || restoring.value || !MiniPlayerPolicy.canLoadInMini(args)) {
      close();
      return false;
    }
    unawaited(_replace(Map<String, dynamic>.from(args)));
    return true;
  }

  Future<void> _replace(Map<String, dynamic> args) async {
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
    final aid = args['aid'] as int;
    final bvid = args['bvid'] as String;
    final cid = args['cid'] as int;
    final result = await MiniPlayerSourceResolver.resolve(
      player,
      aid: aid,
      bvid: bvid,
      cid: cid,
    );
    if (epoch != _epoch || !isHeadless) {
      return;
    }
    switch (result) {
      case Success(:final response?):
        final data = response.data;
        final progress = args.remove('progress') as int? ?? data.lastPlayTime;
        await player.setDataSource(
          NetworkSource(
            videoSource: response.videoUrl,
            audioSource: response.audioUrl,
          ),
          seekTo: progress > 0 ? Duration(milliseconds: progress) : null,
          duration: data.timeLength == null
              ? null
              : Duration(milliseconds: data.timeLength!),
          isVertical: args['isVertical'] ?? false,
          aid: aid,
          bvid: bvid,
          cid: cid,
          videoType: VideoType.ugc,
          width: response.video.width,
          height: response.video.height,
          volume: data.volume,
        );
        if (epoch != _epoch || !isHeadless) {
          return;
        }
        _args = args;
        _playUrl = data;
        _title.value = args['title'] ?? '';
        _cover.value = args['cover'] ?? '';
        _updateMediaItem();
      case Success():
        close();
        PageUtils.toDupNamed(MiniPlayerPolicy.videoRoute, arguments: args);
        return;
      case final Error error:
        error.toast();
      case Loading():
        break;
    }
    loading.value = false;
  }
}
