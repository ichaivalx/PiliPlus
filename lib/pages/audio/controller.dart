import 'dart:async';
import 'dart:io' show Platform;

import 'package:PiliPlus/common/constants.dart';
import 'package:PiliPlus/common/widgets/dialog/simple_dialog_option.dart';
import 'package:PiliPlus/grpc/audio.dart';
import 'package:PiliPlus/grpc/bilibili/app/listener/v1.pb.dart'
    show
        DetailItem,
        PlayURLResp,
        PlaylistSource,
        PlayInfo,
        ThumbUpReq_ThumbType,
        ListOrder,
        DashItem,
        ResponseUrl;
import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/constants.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models/common/audio_normalization.dart';
import 'package:PiliPlus/models/video/play/url.dart' as http_model show Volume;
import 'package:PiliPlus/pages/common/common_intro_controller.dart'
    show FavMixin;
import 'package:PiliPlus/pages/dynamics_repost/view.dart';
import 'package:PiliPlus/pages/main_reply/view.dart';
import 'package:PiliPlus/pages/sponsor_block/block_mixin.dart';
import 'package:PiliPlus/pages/video/controller.dart';
import 'package:PiliPlus/pages/video/introduction/ugc/widgets/triple_mixin.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_repeat.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/services/linked_playback/linked_playback.dart';
import 'package:PiliPlus/services/playback_focus.dart';
import 'package:PiliPlus/services/service_locator.dart';
import 'package:PiliPlus/services/shutdown_timer_service.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/android/android_helper.dart';
import 'package:PiliPlus/utils/connectivity_utils.dart';
import 'package:PiliPlus/utils/extension/iterable_ext.dart';
import 'package:PiliPlus/utils/extension/num_ext.dart';
import 'package:PiliPlus/utils/global_data.dart';
import 'package:PiliPlus/utils/id_utils.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:PiliPlus/utils/share_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:PiliPlus/utils/video_utils.dart';
import 'package:fixnum/fixnum.dart' show Int64;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';

class AudioController extends GetxController
    with
        GetTickerProviderStateMixin,
        TripleMixin,
        FavMixin,
        BlockConfigMixin,
        BlockMixin,
        AudioNormalizationMixin {
  late Int64 id;
  late Int64 oid;
  late List<Int64> subId;
  late int itemType;
  Int64? extraId;
  late final PlaylistSource from;
  @override
  late final bool isUgc = itemType == 1;

  final audioItem = Rxn<DetailItem>();

  Future<void>? _initFuture;
  @override
  Player? player;
  late int cacheAudioQa;

  late bool isDragging = false;
  final RxInt position = RxInt(0);
  final RxInt duration = RxInt(0);

  late final AnimationController animController;

  List<StreamSubscription>? _subscriptions;

  int? index;
  List<DetailItem>? playlist;

  late double speed = 1.0;

  void setSpeed(double value) {
    if (player case final player?) {
      speed = value;
      player.setRate(value);
      _updatePlaybackState();
    }
  }

  late final Rx<PlayRepeat> playMode = Pref.audioPlayMode.obs;

  @override
  late final isLogin = Accounts.main.isLogin;

  Duration? _start;
  VideoDetailController? _videoDetailController;

  String? _prev;
  String? _next;
  bool get reachStart => _prev == null;

  ListOrder order = ListOrder.ORDER_NORMAL;

  double? _lastVolume;
  late final RxDouble desktopVolume = RxDouble(Pref.desktopVolume);

  Timer? _statusTimer;

  void _startStatusTimer() {
    _statusTimer?.cancel();
    _statusTimer = Timer(
      const Duration(milliseconds: 500),
      _updatePlaybackState,
    );
  }

  void _stopStatusTimer() {
    _statusTimer?.cancel();
    _statusTimer = null;
  }

  void toggleVolume() {
    if (_lastVolume == null) {
      _lastVolume = desktopVolume.value;
      setVolume(0, clearLastVolme: false);
    } else {
      setVolume(_lastVolume!);
    }
  }

  void setVolume(double volume, {bool clearLastVolme = true}) {
    if (clearLastVolme) {
      _lastVolume = null;
    }
    desktopVolume.value = volume;
    player?.setVolume(volume * 100);
  }

  void syncVolume([_]) {
    final volume = desktopVolume.value;
    PlPlayerController.instance
      ?..volume.value = volume
      ..videoPlayerController?.setVolume(volume * 100);
    GStorage.setting.put(SettingBoxKey.desktopVolume, volume.toPrecision(3));
  }

  @override
  void onInit() {
    super.onInit();
    final args = Get.arguments;
    oid = Int64(args['oid']);
    final id = args['id'];
    this.id = id != null ? Int64(id) : oid;
    subId = (args['subId'] as List<int>?)?.map(Int64.new).toList() ?? [oid];
    itemType = args['itemType'];
    from = args['from'];
    _start = args['start'];
    final int? extraId = args['extraId'];
    if (extraId != null) {
      this.extraId = Int64(extraId);
    }
    if (args['heroTag'] case String heroTag) {
      try {
        _videoDetailController = Get.find<VideoDetailController>(tag: heroTag);
      } catch (_) {}
    }

    _queryPlayList(isInit: true);

    final String? audioUrl = args['audioUrl'];
    final hasAudioUrl = audioUrl != null;
    if (hasAudioUrl) {
      _querySponsorBlock();
      final request = _beginRequest();
      _onOpenMedia(
        audioUrl,
        ua: BrowserUa.pc,
        referer: HttpString.baseUrl,
        volume: _videoDetailController?.volume,
        start: _takeStart(),
        request: request,
      ).whenComplete(() => shutdownTimerService.endLoad(request.load));
    }
    ConnectivityUtils.isWiFi.then((isWiFi) {
      cacheAudioQa = isWiFi ? Pref.defaultAudioQa : Pref.defaultAudioQaCellular;
      if (!hasAudioUrl) {
        _queryPlayUrl();
      }
    });
    claimMediaControls();
    playbackFocus.addListener(_onVideoPlayback);

    animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );

    shutdownTimerService.addTarget(_shutdownTarget);
  }

  late final ShutdownTarget _shutdownTarget = (
    pause: onPause,
    isPlaying: isPlaying,
  );

  bool isPlaying() {
    return player?.state.playing ?? false;
  }

  /// 本页面位于最上层时由其响应系统媒体控制
  void claimMediaControls() {
    videoPlayerServiceHandler
      ?..onPlay = onPlay
      ..onPause = onPause
      ..onSeek = onSeek
      ..onSkipToNext = playNext
      ..onSkipToPrevious = playPrev;
  }

  /// 已让出给视频播放：返回本页前不自动播放，也不更新系统媒体信息
  bool _yielded = false;

  /// 让出或关闭后，迟到的请求结果不再发布到系统媒体
  bool get _publishesMedia => !_yielded && !isClosed;

  /// 视频开始播放时暂停本页并交出系统媒体控制，返回本页时取回
  void _onVideoPlayback() {
    _yielded = true;
    // 主控的联动内容不再是本页
    linkedPlayback.releaseTarget(_linkedTarget);
    _stopStatusTimer();
    if (isPlaying()) {
      onPause();
    }
    yieldMediaControls();
  }

  void yieldMediaControls() {
    final handler = videoPlayerServiceHandler;
    if (handler != null && handler.onPlay == onPlay) {
      handler
        ..onPlay = null
        ..onPause = null
        ..onSeek = null
        ..onSkipToNext = null
        ..onSkipToPrevious = null;
    }
  }

  /// 返回本页面时取回系统媒体控制与媒体信息，覆盖页面未播放视频时不变
  void reclaimMediaControls() {
    _yielded = false;
    claimMediaControls();
    if (audioItem.value case final item?) {
      _updateCurrItem(item);
    }
    if (player != null) {
      _updatePlaybackState();
    }
  }

  Future<void>? onPlay() {
    if (_takeLinkedPlay()) return Future.value();
    return player?.play();
  }

  /// 本页开始播放前调用：重新取得播放归属的（如返回本页后继续）先重新成为联动的
  /// 内容，再由联动决定是否接管；主控需要与跟随端共同起播时到约定时刻才出声。
  /// 返回是否已接管
  bool _takeLinkedPlay() {
    final player = this.player;
    if (player == null || player.state.playing) return false;
    _resumeLinked();
    return linkedPlayback.takePlay(_linkedTarget);
  }

  Future<void>? onPause() {
    return player?.pause();
  }

  Future<void>? onSeek(Duration duration) {
    _updatePlaybackState(position: duration);
    return player?.seek(duration);
  }

  void _updateCurrItem(DetailItem item) {
    audioItem.value = item;
    hasLike.value = item.stat.hasLike_7;
    coinNum.value = item.stat.hasCoin_8 ? 2 : 0;
    hasFav.value = item.stat.hasFav;
    if (_publishesMedia) {
      videoPlayerServiceHandler?.onVideoDetailChange(
        item,
        (subId.firstOrNull ?? oid).toInt(),
        hashCode.toString(),
      );
    }
  }

  Future<void> _queryPlayList({
    bool isInit = false,
    bool isLoadPrev = false,
    bool isLoadNext = false,
  }) async {
    final res = await AudioGrpc.audioPlayList(
      id: id,
      oid: isInit ? oid : null,
      subId: isInit ? subId : null,
      itemType: isInit ? itemType : null,
      from: isInit ? from : null,
      next: isLoadPrev
          ? _prev
          : isLoadNext
          ? _next
          : null,
      extraId: extraId,
      order: order,
    );
    if (res case Success(:final response)) {
      if (isInit) {
        late final paginationReply = response.paginationReply;
        _prev = response.reachStart ? null : paginationReply.prev;
        _next = response.reachEnd ? null : paginationReply.next;
        final index = response.list.indexWhere((e) => e.item.oid == oid);
        if (index != -1) {
          this.index = index;
          _updateCurrItem(response.list[index]);
          playlist = response.list;
        }
      } else if (isLoadPrev) {
        _prev = response.reachStart ? null : response.paginationReply.prev;
        if (response.list.isNotEmpty) {
          index += response.list.length;
          playlist?.insertAll(0, response.list);
        }
      } else if (isLoadNext) {
        _next = response.reachEnd ? null : response.paginationReply.next;
        if (response.list.isNotEmpty) {
          playlist?.addAll(response.list);
        }
      }
    } else {
      res.toast();
    }
  }

  @pragma('vm:notify-debugger-on-exception')
  void _querySponsorBlock() {
    if (isUgc && enableSponsorBlock) {
      try {
        final bvid = IdUtils.av2bv(oid.toInt());
        final cid = subId.first.toInt();
        querySponsorBlock(bvid: bvid, cid: cid);
      } catch (_) {}
    }
  }

  /// 初始进度只用于进入页面时的那次请求
  Duration? _takeStart() {
    final start = _start;
    _start = null;
    return start;
  }

  Future<bool> _queryPlayUrl() async {
    _querySponsorBlock();
    final start = _takeStart();
    final request = _beginRequest();
    final load = request.load;
    final res = await AudioGrpc.audioPlayUrl(
      itemType: itemType,
      oid: oid,
      subId: subId,
    );
    if (isClosed || !identical(_openingLoad, load)) {
      shutdownTimerService.endLoad(load);
      return false;
    }
    if (res case Success(:final response)) {
      _onPlay(
        response,
        request,
        start,
      ).whenComplete(() => shutdownTimerService.endLoad(load));
      return true;
    } else {
      shutdownTimerService.endLoad(load);
      if (res case Error(:final errMsg)) {
        _linkedFailed(request.cid, errMsg ?? '获取播放地址失败');
      }
      res.toast();
      return false;
    }
  }

  Future<void> _onPlay(
    PlayURLResp data,
    _AudioRequest request,
    Duration? start,
  ) async {
    final PlayInfo? playInfo = data.playerInfo.values.firstOrNull;
    if (playInfo != null) {
      http_model.Volume? volume;
      if (playInfo.hasVolume()) {
        final volumeInfo = playInfo.volume;
        volume = http_model.Volume(
          measuredI: volumeInfo.measuredI,
          measuredLra: volumeInfo.measuredLra,
          measuredTp: volumeInfo.measuredTp,
          measuredThreshold: volumeInfo.measuredThreshold,
          targetOffset: volumeInfo.targetOffset,
          targetI: volumeInfo.targetI,
          targetTp: volumeInfo.targetTp,
        );
      }
      if (playInfo.hasPlayDash()) {
        final playDash = playInfo.playDash;
        final audios = playDash.audio;
        if (audios.isEmpty) {
          _linkedFailed(request.cid, '没有可播放的音频');
          return;
        }
        position.value = 0;
        final audio = audios.findTargetMedia((e) => e.id, cacheAudioQa);
        return _onOpenMedia(
          VideoUtils.getCdnUrl(audio.playUrls),
          volume: volume,
          start: start,
          request: request,
        );
      } else if (playInfo.hasPlayUrl()) {
        final playUrl = playInfo.playUrl;
        final durls = playUrl.durl;
        if (durls.isEmpty) {
          _linkedFailed(request.cid, '没有可播放的音频');
          return;
        }
        final durl = durls.first;
        position.value = 0;
        return _onOpenMedia(
          VideoUtils.getCdnUrl(durl.playUrls),
          volume: volume,
          start: start,
          request: request,
        );
      }
    }
  }

  /// 最近一次打开播放源的请求
  ShutdownLoad? _openingLoad;

  /// 本页所在的路由，用于判断本页实例是否在最上层
  ModalRoute<Object?>? route;

  /// 本页持有播放归属：最近登记播放内容的是本页，或本页正显示在最上层（用户在本页操作）
  bool get _ownsPlayback =>
      linkedPlayback.isCurrentOwner(_linkedTarget) || (route?.isCurrent ?? false);

  /// 发出请求时固定分P 与联动内容，以最近一次请求为准，迟到的旧结果不再打开
  _AudioRequest _beginRequest() {
    // 最上层（或正在打开的）本页发起的请求取得播放归属，后台页面的续播不能再作废它
    if (route?.isCurrent ?? true) {
      linkedPlayback.claim(_linkedTarget);
    }
    // 重新加载：此前的失败不再有效，进行中的等待打开结束
    _failedCid = null;
    _openWait?.cancel();
    final load = _openingLoad = shutdownTimerService.beginLoad();
    return _AudioRequest(
      load: load,
      cid: (subId.firstOrNull ?? oid).toInt(),
      content: _linkedContent,
      epoch: linkedPlayback.epoch,
    );
  }

  Future<void> _onOpenMedia(
    String url, {
    String ua = Constants.userAgentApp,
    String? referer,
    http_model.Volume? volume,
    Duration? start,
    required _AudioRequest request,
  }) async {
    final load = request.load;
    await _initPlayerIfNeeded();
    final player = this.player;
    if (player == null || !identical(_openingLoad, load)) {
      return;
    }
    final extras = audioFilterExtras(volume);
    player.setMediaHeader(
      userAgent: ua,
      // mpv cannot clear referer option
      headers: {'Referer': ?referer},
    );
    _loadedCid = null;
    // 已让出给视频，或请求期间其他页面（如视频）已登记播放内容，或本页已不持有
    // 播放归属（如视频已登记、正等待起播时本页自动续播）：不登记为联动内容，也不自动播放
    final superseded =
        linkedPlayback.epoch != request.epoch || !_ownsPlayback;
    final linkedLoad = _yielded || superseded
        ? null
        : linkedPlayback.gateLoad(
            request.content,
            _linkedTarget,
            // 本次加载的停止、暂缓状态随加载转交给联动
            autoplay: () => !_yielded,
            load: load,
          );
    // 打开命令返回时文件尚未打开，以实际打开的结果为准；打开前订阅，不漏掉打开
    // 期间的失败事件
    final wait = _openWait = _OpenWait(player);
    final String? failure;
    try {
      await player.open(
        Media(url, start: linkedLoad?.position ?? start, extras: extras),
        play: false,
      );
      failure = await wait.result;
    } finally {
      wait.cancel();
      if (identical(_openWait, wait)) _openWait = null;
    }
    // 已被新请求取代或页面已关闭时不播放
    if (isClosed ||
        !identical(_openingLoad, load) ||
        !identical(this.player, player)) {
      return;
    }
    if (failure == null) {
      _loadedCid = request.cid;
    } else {
      // 联动的加载完成回调按未加载处理；之后同一内容可重新取地址并打开
      _linkedFailed(request.cid, '音频打开失败');
    }
    if (linkedLoad != null) {
      if (_yielded) {
        // 加载期间让出给视频
        linkedPlayback.releaseTarget(_linkedTarget);
      } else {
        linkedLoad.loaded();
      }
      return;
    }
    // 定时关闭在加载期间到期或已让出给视频时不再播放
    if (failure == null &&
        !_yielded &&
        !superseded &&
        shutdownTimerService.canAutoplay(load)) {
      player.play();
    }
  }

  /// 进行中的等待打开，新请求或页面关闭时提前结束
  _OpenWait? _openWait;

  // 联动播放

  late final _linkedTarget = _AudioLinkedTarget(this);

  /// 已实际打开的分P，打开新的播放源期间及打开失败时为空
  int? _loadedCid;

  /// 最近一次加载失败的分P，重新加载时清除
  int? _failedCid;
  String? _failure;

  /// 可联动播放的内容：普通视频的分P
  LinkedContent? get _linkedContent {
    if (!isUgc) return null;
    final aid = oid.toInt();
    final arc = audioItem.value?.arc;
    return LinkedContent(
      kind: LinkedKind.audio,
      bvid: IdUtils.av2bv(aid),
      aid: aid,
      cid: (subId.firstOrNull ?? oid).toInt(),
      title: arc?.title,
      cover: arc?.cover,
    );
  }

  void _linkedFailed(int cid, String reason) {
    if (!isUgc) return;
    _failedCid = cid;
    _failure = reason;
    linkedPlayback.loadFailed(LinkedKind.audio, cid, reason);
  }

  /// 开始或继续播放已加载的内容（如返回本页后继续）时重新成为联动的内容
  void _resumeLinked() {
    final cid = _loadedCid;
    if (_yielded || cid == null) return;
    // 只有最上层本页的主动恢复或仍持有归属时才重新登记；后台页的自动重播、迟到的
    // 播放事件不覆盖前台页面已登记的内容
    if (!(route?.isCurrent ?? false) &&
        !linkedPlayback.isCurrentOwner(_linkedTarget)) {
      return;
    }
    final content = _linkedContent;
    if (content != null && content.cid != cid) return;
    linkedPlayback.resume(content, _linkedTarget);
  }

  /// 联动播放切换到同页面的另一内容
  void _openLinked(LinkedContent content) {
    id = oid = Int64(content.aid);
    subId = [Int64(content.cid)];
    itemType = 1;
    _videoDetailController = null;
    _queryPlayList(isInit: true);
    _queryPlayUrl();
  }

  PlayerStatus _playerStatus = .paused;
  void _updatePlaybackState({Duration? position, String? debugLabel}) {
    if (!_publishesMedia) {
      return;
    }
    videoPlayerServiceHandler?.onUpdateState(
      _playerStatus,
      false,
      false,
      position: position ?? player!.state.position,
      speed: speed,
      debugLabel: debugLabel,
    );
  }

  /// 并发请求共用同一次播放器创建
  Future<void> _initPlayerIfNeeded() => _initFuture ??= _initPlayer();

  Future<void> _initPlayer() async {
    assert(player == null, _subscriptions = null);
    player = await Player.create(
      configuration: PlayerConfiguration(
        options: {
          if (Platform.isAndroid) 'ao': Pref.audioOutput,
          'volume': PlatformUtils.isDesktop
              ? (desktopVolume.value * 100).toString()
              : Pref.playerVolume.toString(),
          ...Pref.initBuffer(),
        },
      ),
    );
    if (isClosed) {
      player!.dispose();
      player = null;
      return;
    }
    final stream = player!.stream;
    _subscriptions = [
      stream.position.listen((position) {
        if (isDragging) return;
        final seconds = position.inSeconds;
        if (seconds != this.position.value) {
          if (seconds == 0 && _playerStatus.isPlaying) {
            _updatePlaybackState(position: position);
          }
          this.position.value = seconds;
          _videoDetailController?.playedTime = position;
        }
      }),
      stream.duration.listen((duration) {
        this.duration.value = duration.inSeconds;
      }),
      stream.playing.listen((playing) {
        if (playing) {
          _resumeLinked();
          animController.forward();
          _playerStatus = .playing;
          _stopStatusTimer();
          _updatePlaybackState();
        } else {
          animController.reverse();
          _playerStatus = .paused;
          _startStatusTimer();
        }
      }),
      stream.buffering.listen((bool buffering) {
        if (!_playerStatus.isCompleted) {
          _stopStatusTimer();
          _updatePlaybackState();
        }
      }),
      stream.completed.listen((completed) {
        _videoDetailController?.playedTime = player!.state.duration;
        if (completed) {
          _playerStatus = .completed;
          _startStatusTimer();
          if (shutdownTimerService.isWaiting) {
            shutdownTimerService.handleWaiting();
          } else if (!linkedPlayback.isFollowing) {
            // 联动跟随时由主控决定下一项
            switch (playMode.value) {
              case PlayRepeat.pause:
                break;
              case PlayRepeat.listOrder:
                playNext(nextPart: true);
                break;
              case PlayRepeat.singleCycle:
                onPlay();
                break;
              case PlayRepeat.listCycle:
                if (!playNext(nextPart: true)) {
                  if (index != null && index != 0 && playlist != null) {
                    playIndex(0);
                  } else {
                    onPlay();
                  }
                }
                break;
              case PlayRepeat.autoPlayRelated:
                break;
            }
          }
        }
      }),
    ];
  }

  @override
  Future<void> actionLikeVideo() async {
    if (!isLogin) {
      SmartDialog.showToast('账号未登录');
      return;
    }
    final newVal = !hasLike.value;
    final res = await AudioGrpc.audioThumbUp(
      oid: oid,
      subId: subId,
      itemType: itemType,
      type: newVal
          ? ThumbUpReq_ThumbType.LIKE
          : ThumbUpReq_ThumbType.CANCEL_LIKE,
    );
    if (res case Success(:final response)) {
      hasLike.value = newVal;
      try {
        audioItem.value!.stat
          ..hasLike_7 = newVal
          ..like += newVal ? 1 : -1;
        audioItem.refresh();
      } catch (_) {}
      SmartDialog.showToast(response.message);
    } else {
      res.toast();
    }
  }

  @override
  Future<void> actionTriple() async {
    if (!isLogin) {
      SmartDialog.showToast('账号未登录');
      return;
    }
    final res = await AudioGrpc.audioTripleLike(
      oid: oid,
      subId: subId,
      itemType: itemType,
    );
    if (res case Success(:final response)) {
      hasLike.value = true;
      if (response.coinOk && !hasCoin) {
        coinNum.value = 2;
        GlobalData().afterCoin(2);
        try {
          audioItem.value!.stat
            ..hasCoin_8 = true
            ..coin += 2;
          audioItem.refresh();
        } catch (_) {}
      }
      hasFav.value = true;
      if (!hasCoin) {
        SmartDialog.showToast('投币失败');
      } else {
        SmartDialog.showToast('三连成功');
      }
    } else {
      res.toast();
    }
  }

  @override
  int get copyright => audioItem.value?.arc.copyright ?? 1;

  @override
  Future<void> onPayCoin(int coin, bool coinWithLike) async {
    final res = await AudioGrpc.audioCoinAdd(
      oid: oid,
      subId: subId,
      itemType: itemType,
      num: coin,
      thumbUp: coinWithLike,
    );
    if (res.isSuccess) {
      final updateLike = !hasLike.value && coinWithLike;
      if (updateLike) {
        hasLike.value = true;
      }
      coinNum.value += coin;
      try {
        final stat = audioItem.value!.stat
          ..hasCoin_8 = true
          ..coin += coin;
        if (updateLike) {
          stat
            ..hasLike_7 = true
            ..like += 1;
        }
        audioItem.refresh();
      } catch (_) {}
      GlobalData().afterCoin(coin);
    } else {
      res.toast();
    }
  }

  @override
  void showFavBottomSheet(BuildContext context, {bool isLongPress = false}) {
    if (!isLogin) {
      SmartDialog.showToast('账号未登录');
      return;
    }
    if (enableQuickFav) {
      if (!isLongPress) {
        actionFavVideo(isQuick: true);
      } else {
        PageUtils.showFavBottomSheet(context: context, ctr: this);
      }
    } else if (!isLongPress) {
      PageUtils.showFavBottomSheet(context: context, ctr: this);
    }
  }

  void showReply() {
    MainReplyPage.toMainReplyPage(
      oid: oid.toInt(),
      replyType: isUgc ? 1 : 14,
    );
  }

  void actionShareVideo(BuildContext context) {
    final audioUrl = isUgc
        ? '${HttpString.baseUrl}/video/${IdUtils.av2bv(oid.toInt())}'
        : '${HttpString.baseUrl}/audio/au$oid';
    showDialog(
      context: context,
      builder: (_) => SimpleDialog(
        clipBehavior: Clip.hardEdge,
        contentPadding: const EdgeInsets.symmetric(vertical: 12),
        children: [
          DialogOption(
            child: const Text('复制链接', style: TextStyle(fontSize: 14)),
            onPressed: () {
              Get.back();
              Utils.copyText(audioUrl);
            },
          ),
          DialogOption(
            child: const Text('其它app打开', style: TextStyle(fontSize: 14)),
            onPressed: () {
              Get.back();
              PiliAndroidHelper.openUrl(audioUrl);
            },
          ),
          if (PlatformUtils.isMobile)
            DialogOption(
              child: const Text('分享视频', style: TextStyle(fontSize: 14)),
              onPressed: () {
                Get.back();
                if (audioItem.value case DetailItem(
                  :final arc,
                  :final owner,
                )) {
                  ShareUtils.shareText(
                    '${arc.title} '
                    'UP主: ${owner.name}'
                    ' - $audioUrl',
                  );
                }
              },
            ),
          if (isLogin)
            DialogOption(
              child: const Text('分享至动态', style: TextStyle(fontSize: 14)),
              onPressed: () {
                Get.back();
                if (audioItem.value case DetailItem(
                  :final arc,
                  :final owner,
                )) {
                  showModalBottomSheet(
                    context: context,
                    isScrollControlled: true,
                    useSafeArea: true,
                    builder: (context) => RepostPanel(
                      rid: oid.toInt(),
                      dynType: isUgc ? 8 : 256,
                      pic: arc.cover,
                      title: arc.title,
                      uname: owner.name,
                    ),
                  );
                }
              },
            ),
          if (isUgc && isLogin)
            DialogOption(
              child: const Text('分享至消息', style: TextStyle(fontSize: 14)),
              onPressed: () {
                Get.back();
                if (audioItem.value case DetailItem(
                  :final arc,
                  :final owner,
                )) {
                  try {
                    PageUtils.pmShare(
                      context,
                      content: {
                        "id": oid.toString(),
                        "title": arc.title,
                        "headline": arc.title,
                        "source": 5,
                        "thumb": arc.cover,
                        "author": owner.name,
                        "author_id": owner.mid.toString(),
                      },
                    );
                  } catch (e) {
                    SmartDialog.showToast(e.toString());
                  }
                }
              },
            ),
        ],
      ),
    );
  }

  Future<void>? playOrPause() {
    if (_takeLinkedPlay()) return Future.value();
    return player?.playOrPause();
  }

  bool playPrev() {
    if (index != null && playlist != null && player != null) {
      final prev = index! - 1;
      if (prev >= 0) {
        playIndex(prev);
        return true;
      }
    }
    return false;
  }

  bool playNext({bool nextPart = false}) {
    if (nextPart) {
      if (audioItem.value case DetailItem(:final parts)) {
        if (parts.length > 1) {
          final subId = this.subId.firstOrNull;
          final nextIndex = parts.indexWhere((e) => e.subId == subId) + 1;
          if (nextIndex != 0 && nextIndex < parts.length) {
            final nextPart = parts[nextIndex];
            oid = nextPart.oid;
            this.subId = [nextPart.subId];
            _queryPlayUrl().then((res) {
              if (res) {
                _videoDetailController = null;
              }
            });
            return true;
          }
        }
      }
    }
    if (index != null && playlist != null && player != null) {
      final next = index! + 1;
      if (next < playlist!.length) {
        if (next == playlist!.length - 1 && _next != null) {
          _queryPlayList(isLoadNext: true);
        }
        playIndex(next);
        return true;
      }
    }
    return false;
  }

  void playIndex(int index, {List<Int64>? subId}) {
    if (index == this.index && subId == null) return;
    this.index = index;
    final audioItem = playlist![index];
    final item = audioItem.item;
    oid = item.oid;
    this.subId =
        subId ??
        (item.subId.isNotEmpty ? item.subId : [audioItem.parts.first.subId]);
    itemType = item.itemType;
    _queryPlayUrl().then((res) {
      if (res) {
        _videoDetailController = null;
        _updateCurrItem(audioItem);
      }
    });
  }

  @override
  (Object, int) get getFavRidType => (oid, isUgc ? 2 : 12);

  @override
  void updateFavCount(int count) {
    try {
      audioItem.value!.stat
        ..hasFav = count > 0
        ..favourite += count;
      audioItem.refresh();
    } catch (_) {}
  }

  Future<void> loadPrev(BuildContext context) async {
    if (_prev == null) return;
    final length = playlist!.length;
    await _queryPlayList(isLoadPrev: true);
    if (length != playlist!.length && context.mounted) {
      (context as Element).markNeedsBuild();
    }
  }

  Future<void> loadNext(BuildContext context) async {
    if (_next == null) return;
    final length = playlist!.length;
    await _queryPlayList(isLoadNext: true);
    if (length != playlist!.length && context.mounted) {
      (context as Element).markNeedsBuild();
    }
  }

  void onChangeOrder(ListOrder value) {
    if (order != value) {
      order = value;
      _queryPlayList(isInit: true);
    }
  }

  @override
  BlockConfigMixin get blockConfig => this;

  @override
  int get currPosInMilliseconds => player?.state.position.inMilliseconds ?? 0;

  @override
  int? get timeLength => player?.state.duration.inMilliseconds ?? 0;

  @override
  Future<void>? seekTo(Duration duration, {required bool isSeek}) =>
      onSeek(duration);

  @override
  bool get autoPlay => true;

  @override
  bool get preInitPlayer => true;

  @override
  void onClose() {
    _openWait?.cancel();
    linkedPlayback.releaseTarget(_linkedTarget);
    _stopStatusTimer();
    shutdownTimerService.removeTarget(_shutdownTarget);
    playbackFocus.removeListener(_onVideoPlayback);
    yieldMediaControls();
    videoPlayerServiceHandler
      ?..onVideoDetailDispose(hashCode.toString())
      ..clearIfNeeded();
    _subscriptions?.forEach((e) => e.cancel());
    _subscriptions?.clear();
    _subscriptions = null;
    player?.dispose();
    player = null;
    animController.dispose();
    super.onClose();
  }
}

/// 一次播放地址请求：发出时的加载许可、分P、联动内容与登记代次
class _AudioRequest {
  const _AudioRequest({
    required this.load,
    required this.cid,
    required this.content,
    required this.epoch,
  });

  final ShutdownLoad load;
  final int cid;
  final LinkedContent? content;
  final int epoch;
}

/// 等待一次播放源实际打开：时长可用即打开成功，返回 null；打开失败、超时返回原因；
/// 被新请求取代、页面关闭、播放器释放时提前结束并返回 null，由调用方按已被取代处理。
/// 在打开前订阅以捕获新源早期的失败；打开时先停止旧源并发出零时长，此前的事件
/// 属于旧源，不计入
final class _OpenWait {
  _OpenWait(Player player) {
    _subscriptions = [
      player.stream.duration.listen((duration) {
        if (duration == Duration.zero) {
          _started = true;
        } else if (_started) {
          _finish(null);
        }
      }, onDone: cancel),
      player.stream.error.listen((error) {
        if (_started &&
            (error.startsWith('Failed to open') ||
                error.startsWith('Failed to recognize file format'))) {
          _finish(error);
        }
      }, onDone: cancel),
    ];
    _timer = Timer(_timeout, () => _finish('打开超时'));
  }

  /// 打开的上限，超时按失败处理，之后可重新取地址并打开
  static const _timeout = Duration(seconds: 20);

  /// 旧源已停止，此后的事件属于本次打开
  bool _started = false;

  final _completer = Completer<String?>();
  late final List<StreamSubscription<Object>> _subscriptions;
  late final Timer _timer;

  Future<String?> get result => _completer.future;

  void cancel() => _finish(null);

  void _finish(String? failure) {
    if (_completer.isCompleted) return;
    _timer.cancel();
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _completer.complete(failure);
  }
}

final class _AudioLinkedTarget implements LinkedTarget {
  _AudioLinkedTarget(this._controller);

  final AudioController _controller;

  @override
  LinkedKind get kind => LinkedKind.audio;

  @override
  bool get isActive => !_controller.isClosed;

  @override
  bool get isLoading =>
      _controller._loadedCid == null && _controller._failedCid == null;

  @override
  Player? playerFor(int cid) {
    final player = _controller.player;
    if (_controller.isClosed ||
        player == null ||
        player.disposed ||
        _controller._loadedCid != cid) {
      return null;
    }
    return player;
  }

  @override
  String? failureFor(int cid) =>
      _controller._failedCid == cid ? _controller._failure : null;

  @override
  double get rate => _controller.speed;

  @override
  Future<void> setRate(double rate) async {
    _controller.setSpeed(rate);
  }

  @override
  Future<void> play() async {
    await _controller.onPlay();
  }

  @override
  void resume() => _controller.onPlay();

  @override
  Future<void> pause() async {
    await _controller.onPause();
  }

  @override
  Future<void> seek(Duration position) async {
    await _controller.player?.seek(position);
  }

  @override
  bool open(LinkedContent content) {
    if (_controller.isClosed) return false;
    _controller._openLinked(content);
    return true;
  }
}

extension on DashItem {
  Iterable<String> get playUrls sync* {
    yield baseUrl;
    yield* backupUrl;
  }
}

extension on ResponseUrl {
  Iterable<String> get playUrls sync* {
    yield url;
    yield* backupUrl;
  }
}
