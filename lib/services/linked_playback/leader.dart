import 'dart:async';

import 'package:PiliPlus/services/linked_playback/clock.dart';
import 'package:PiliPlus/services/linked_playback/models.dart';
import 'package:PiliPlus/services/linked_playback/player_access.dart';
import 'package:PiliPlus/services/linked_playback/protocol.dart';
import 'package:PiliPlus/services/linked_playback/target.dart';
import 'package:PiliPlus/services/linked_playback/transport.dart';
import 'package:PiliPlus/services/shutdown_timer_service.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:media_kit/media_kit.dart';

enum _Phase {
  /// 各端加载本轮内容
  loading,

  /// 各端暂停、定位并缓冲
  preparing,

  /// 已约定起播时刻
  starting,
}

/// 一轮共同起播：加载 → 定位就绪 → 约定时刻共同开始；新一轮开始时旧的作废
class _Round {
  _Round(
    this.id, {
    required this.intendsPlay,
    required this.selfLoaded,
    required this.participants,
    required this.loading,
  });

  final int id;

  /// 就绪后是否开始播放；期间用户的播放、暂停更新此值
  bool intendsPlay;

  /// 起播的许可，起播前复核：页面加载时的自动播放许可（如定时关闭在加载期间到期后
  /// 不再许可），及轮次期间的停止播放（拔出耳机）、音频打断；用户手动播放解除此前的
  /// 禁止，之后的停止播放、打断仍可撤销
  bool Function()? permits;

  /// 轮次期间登记的待自动播放，使停止播放、音频打断能撤销本轮起播；起播或作废时注销，
  /// 重新就绪时连同许可转交给新一轮
  ShutdownLoad? load;

  /// 页面加载时的自动播放许可，用户手动播放后不再适用
  bool Function()? autoplay;

  bool selfLoaded;
  bool selfReady = false;

  /// 开始定位就绪时页面已发起的定位次数，之后再有定位即为再次拖动
  int seeks = 0;

  _Phase phase = _Phase.loading;
  int? position;

  /// 参与本轮的跟随端，超时未响应的移出
  final Set<LinkConnection> participants;
  final Set<LinkConnection> loading;
  final Set<LinkConnection> preparing = {};
  Timer? timer;
}

class _PeerState {
  _PeerState(this.address);

  final String address;

  /// 跟随端的设备标识与名称，收到 hello 后才有
  String? id;
  String? name;

  /// 被同一设备的新连接取代，断开时不显示为离线
  bool replaced = false;

  /// 尚未收到本机当前播放的内容
  bool needsContent = false;

  LinkedPeerState state = LinkedPeerState.idle;
  String? reason;
  double? driftMs;
  double? rttMs;
  LinkedVolume? volume;

  /// 跟随端的延迟偏移，以其回报为准
  int? offsetUs;

  /// 本机最近设置的偏移及时刻：连续调节时跟随端依次回报的旧值不覆盖
  int? setOffsetUs;
  int setOffsetAt = 0;

  LinkedPeerInfo info({LinkedPeerState? state}) => LinkedPeerInfo(
    id: id ?? address,
    name: name ?? address,
    address: address,
    state: state ?? this.state,
    reason: reason,
    driftMs: driftMs,
    rttMs: rttMs,
    volume: volume,
    offsetUs: offsetUs,
  );
}

/// 主控：本机播放的内容与播放操作同步给所有跟随端
class LeaderSession {
  LeaderSession({
    required this.syncOn,
    required this.onSyncRequest,
    required this.onPeersChanged,
    required this.seekTogether,
  });

  static const _tickInterval = Duration(milliseconds: 250);
  static const _loadTimeout = Duration(seconds: 20);
  static const _prepareTimeout = Duration(seconds: 10);

  /// 约定起播时刻距发出指令的时间，需大于网络单程延迟
  static const _startLeadUs = 350000;

  /// 播放中位置的跳变超过此值视为拖动进度
  static const _seekJumpUs = 1000000;

  /// 拖动进度后此时间内的缓冲不视为卡顿：跟随端已暂停，等本机恢复播放后跳转加入
  static const _seekGraceUs = 10000000;

  /// 暂停时位置变化超过此值时同步给跟随端
  static const _pausedMoveUs = 150000;

  /// 连续卡顿的检查次数，达到后共同暂停并重新共同起播
  static const _stallTicks = 3;

  /// 超过此时间未收到消息的跟随端可能已断开，不参与共同起播，
  /// 恢复后自行跳转加入
  static const _freshUs = 2500000;

  /// 设置跟随端的偏移后在此时间内忽略其回报的其他值
  static const _offsetEchoUs = 1000000;

  final bool Function() syncOn;
  final void Function(bool) onSyncRequest;
  final void Function(List<LinkedPeerInfo>) onPeersChanged;

  /// 播放中拖动进度时两端共同暂停、定位后共同起播；否则本机照常播放，跟随端追上
  final bool Function() seekTogether;

  late final _transport = LeaderTransport(
    onConnected: _onConnected,
    onMessage: _onMessage,
    onDisconnected: _onDisconnected,
  );
  final Map<LinkConnection, _PeerState> _peers = {};

  /// 本机的系统媒体音量
  double? _volume;

  /// 曾连接过、当前离线的跟随端
  final Map<String, LinkedPeerInfo> _offline = {};
  Timer? _ticker;

  /// 已不再与跟随端一起起播、等待本机加载完成后自行播放的轮次
  _Round? _standaloneRound;

  /// 本机当前播放的可联动内容及所在页面
  LinkedContent? _content;
  LinkedTarget? _target;
  int _roundId = 0;
  _Round? _round;

  /// 本机播放器应处的状态，与之不符的变化来自用户或页面的操作
  bool _expectPlaying = false;

  Player? _player;
  bool _synced = false;
  final List<StreamSubscription> _subscriptions = [];
  ({int pos, int at})? _lastPosition;
  int? _pausedPos;
  int _stall = 0;
  int _seekAt = -_seekGraceUs;

  bool get hasPeers => _transport.connections.isNotEmpty;

  /// 会话已结束：仅剩归还给本机的自行起播
  bool _closed = false;

  /// 页面对当前播放器发起的定位次数，不含联动自身的定位
  int _userSeeks = 0;
  bool _ownSeek = false;

  /// 页面发起定位（拖动进度、快进快退等）时调用，在定位开始前同步调用
  void noteSeek(LinkedTarget target) {
    if (!_ownSeek && identical(target, _target)) _userSeeks++;
  }

  /// 正在与跟随端一起播放
  bool get _active => !_closed && hasPeers && syncOn();

  Future<void> start() async {
    await _transport.start();
    _ticker = Timer.periodic(_tickInterval, _tick);
  }

  /// 结束会话并通知跟随端停止；返回的 Future 在停止消息发出、连接关闭后完成。
  /// [handBack] 为结束联动、归还本机播放：进行中的共同起播按播放意图与许可由本机
  /// 自行播放，未加载完时加载完成后播放（同关闭同步）；否则（定时停止、退出）作废
  Future<void> dispose({bool handBack = false}) {
    _closed = true;
    _ticker?.cancel();
    final round = _round;
    _transport.broadcast(const {'t': LinkMessageType.stop});
    final closing = _transport.dispose();
    _peers.clear();
    _detach();
    if (handBack) {
      _standalone(round);
    } else {
      _cancelRound();
      _clearStandalone();
    }
    return closing;
  }

  /// 已结束的会话不再等待归还的自行起播（其他页面开始加载、页面关闭等）
  void abandon() {
    _cancelRound();
    _clearStandalone();
  }

  void refresh() => _transport.refresh();

  Map<String, Object?> get _syncMessage => {
    't': LinkMessageType.sync,
    'on': syncOn(),
  };

  Player? get _loadedPlayer {
    final content = _content;
    return content == null ? null : _target?.playerFor(content.cid);
  }

  // 页面接入

  /// 会话启动时接管页面已加载的内容与播放状态
  void adopt(LinkedContent? content, LinkedTarget target) {
    _setTarget(content, target);
    if (_loadedPlayer case final player?) {
      _attach(player);
      _expectPlaying = player.state.playing;
    }
  }

  LinkedLoad? gateLoad(
    LinkedContent? content,
    LinkedTarget target, {
    required bool Function() autoplay,
    required ShutdownLoad load,
  }) {
    _setTarget(content, target);
    _clearStandalone();
    if (!_active) return null;
    _cancelRound();
    _expectPlaying = false;
    for (final state in _peers.values) {
      state.needsContent = false;
    }
    if (content == null) {
      _restorePlayer();
      _transport.broadcast(const {'t': LinkMessageType.stop});
      return null;
    }
    final round = _beginRound(
      intendsPlay: autoplay(),
      selfLoaded: false,
      autoplay: autoplay,
      from: load,
    );
    _transport.broadcast(_open(round.id));
    return LinkedLoad(onLoaded: () => _onSelfLoaded(round));
  }

  /// 其他页面取得播放归属：[target] 进行中的共同起播（含等待自行起播）作废，不再起播
  void supersede(LinkedTarget target) {
    if (!identical(_target, target)) return;
    final round = _round;
    _cancelRound();
    _clearStandalone();
    // 跟随端可能已在定位或已约定起播时刻：广播暂停作废其起播
    if (round != null && round.phase != _Phase.loading && _active) {
      if (_loadedPlayer case final player?) {
        _broadcastPause(player);
      }
    }
  }

  /// 页面交出播放器（未交给小窗）：进行中的共同起播作废；正在一起播放时跟随端
  /// 随之暂停。在页面交出前调用，此时仍可读取播放位置
  void yieldTarget(LinkedTarget target) {
    if (!identical(_target, target)) return;
    final player = _loadedPlayer;
    final playing = _expectPlaying;
    supersede(target);
    _expectPlaying = false;
    if (playing && _active && player != null) {
      _broadcastPause(player);
    }
  }

  /// 页面继续播放已加载的内容（未经加载流程，如返回听视频页继续播放）：
  /// 改由该页面联动，跟随端按其进度加入
  void takeOver(LinkedContent? content, LinkedTarget target) {
    _cancelRound();
    _clearStandalone();
    _setTarget(content, target);
    if (!_active) return;
    if (content == null) {
      _restorePlayer();
      _transport.broadcast(const {'t': LinkMessageType.stop});
      return;
    }
    for (final state in _peers.values) {
      state.needsContent = state.id != null;
    }
    _sendContent();
  }

  /// 换到另一页面时不再联动原页面的播放器
  void _setTarget(LinkedContent? content, LinkedTarget target) {
    if (!identical(target, _target)) _detach();
    _content = content;
    _target = target;
  }

  /// 页面关闭，不再持有播放器
  void releaseTarget(LinkedTarget target) {
    if (!identical(_target, target)) return;
    _target = null;
    _content = null;
    _clearStandalone();
    _cancelRound();
    _expectPlaying = false;
    _detach();
    _transport.broadcast(const {'t': LinkMessageType.stop});
  }

  Map<String, Object?> _open(int round) => {
    't': LinkMessageType.open,
    'round': round,
    'content': _content!.toJson(),
  };

  void _onSelfLoaded(_Round round) {
    if (identical(round, _standaloneRound)) {
      // 等待期间已不再与跟随端一起起播：按播放意图自行播放
      round.selfLoaded = true;
      _playIfIntended(round);
      _clearStandalone();
      if (_loadedPlayer == null && _active) {
        // 加载失败
        _transport.broadcast(const {'t': LinkMessageType.stop});
      }
      return;
    }
    if (!identical(_round, round)) return;
    final player = _loadedPlayer;
    if (player == null) {
      // 加载失败
      _cancelRound();
      _transport.broadcast(const {'t': LinkMessageType.stop});
      return;
    }
    _attach(player);
    round.selfLoaded = true;
    _advance(round);
  }

  // 同步开关、音量、定时关闭

  /// 同步开关变化后调用
  void applySync() {
    _transport.broadcast(_syncMessage);
    if (syncOn()) {
      for (final state in _peers.values) {
        state.needsContent = state.id != null;
      }
      _sendContent();
      return;
    }
    final round = _round;
    _restorePlayer();
    _transport.broadcast(const {'t': LinkMessageType.stop});
    _standalone(round);
  }

  /// 不再与跟随端一起起播：本机已加载时按播放意图直接播放，未加载完时由加载完成后
  /// 自行播放（加载由联动接管，页面已关闭自动播放）
  void _standalone(_Round? round) {
    if (round != null && !round.selfLoaded) {
      // 先登记，作废轮次时保留其自动播放许可
      _clearStandalone();
      _standaloneRound = round;
    }
    _cancelRound();
    if (round != null && round.selfLoaded) {
      _playIfIntended(round);
    }
  }

  void _clearStandalone() {
    _dropDeferred();
    final round = _standaloneRound;
    _standaloneRound = null;
    if (round != null) _endLoad(round);
  }

  /// 仍与跟随端联动时本机播放后按播放进度同步，跟随端跳转加入
  void _playIfIntended(_Round round) {
    final player = _loadedPlayer;
    if (player == null) return;
    _attach(player);
    if (round.intendsPlay &&
        (round.permits?.call() ?? true) &&
        !player.state.playing) {
      _expectPlaying = true;
      _lastPosition = null;
      _stall = 0;
      _target!.play();
    }
  }

  /// 本机系统媒体音量变化，跟随主控的跟随端随之调整
  void onLocalVolume(double volume) {
    _volume = volume;
    _transport.broadcast(_volumeMessage);
  }

  Map<String, Object?> get _volumeMessage => {
    't': LinkMessageType.volume,
    'v': ?_volume,
  };

  void setVolume(String id, LinkedVolume volume) {
    for (final MapEntry(key: peer, value: state) in _peers.entries) {
      if (state.id == id) {
        state.volume = volume;
        peer.send({'t': LinkMessageType.volumeSet, ...volume.toJson()});
      }
    }
    _notifyPeers();
  }

  /// 设置设备标识为 [id] 的跟随端的延迟偏移
  void setOffset(String id, int offsetUs) {
    for (final MapEntry(key: peer, value: state) in _peers.entries) {
      if (state.id == id) {
        state
          ..offsetUs = offsetUs
          ..setOffsetUs = offsetUs
          ..setOffsetAt = LinkClock.nowUs;
        peer.send({'t': LinkMessageType.offset, 'us': offsetUs});
      }
    }
    _notifyPeers();
  }

  /// 本机与各跟随端一起停止，进行中的共同起播不再开始播放
  void pauseAll() {
    // 因打断暂缓的共同起播不再在打断结束后继续
    _dropDeferred();
    _standaloneRound?.intendsPlay = false;
    final round = _round;
    if (round != null) {
      round.intendsPlay = false;
      // 已约定起播时刻：作废本机的定时起播，跟随端收到暂停后作废其定时起播
      if (round.phase == _Phase.starting) {
        _cancelRound();
      }
    }
    final player = _loadedPlayer;
    if (player == null) return;
    // 直接广播暂停，不依赖之后的播放器事件；进行中的轮次由起播时按不播放处理
    if (_active && _round == null) {
      _expectPlaying = false;
      _broadcastPause(player);
    }
    if (player.state.playing) {
      _target!.pause();
    }
  }

  // 轮次

  /// [loading] 为空时等待所有跟随端加载
  _Round _beginRound({
    required bool intendsPlay,
    required bool selfLoaded,
    Iterable<LinkConnection>? loading,
    bool Function()? autoplay,
    ShutdownLoad? from,
    _Round? inherit,
  }) {
    // 转交的许可在作废旧轮次前取出，不随旧轮次注销
    final inherited = inherit?.load;
    inherit?.load = null;
    _cancelRound();
    _dropDeferred();
    final now = LinkClock.nowUs;
    final participants = {
      for (final MapEntry(key: peer, value: state) in _peers.entries)
        if (state.id != null &&
            now - peer.lastReceived < _freshUs &&
            state.state != LinkedPeerState.localPaused)
          peer,
    };
    final round = _round = _Round(
      ++_roundId,
      intendsPlay: intendsPlay,
      selfLoaded: selfLoaded,
      participants: participants,
      loading: (loading ?? participants).toSet(),
    );
    if (inherit != null && inherited != null) {
      round
        ..load = inherited
        ..permits = inherit.permits
        ..autoplay = inherit.autoplay;
    } else {
      // 沿用页面加载已有的停止、暂缓状态，此后的事件由本轮的登记承接
      final load = round.load = shutdownTimerService.beginLoad(from: from);
      round
        ..autoplay = autoplay
        ..permits = () =>
            shutdownTimerService.canAutoplay(load) &&
            (autoplay?.call() ?? true);
    }
    round.timer = Timer(_loadTimeout, () => _onLoadTimeout(round));
    return round;
  }

  /// 作废当前轮次；转为等待自行起播的轮次保留其自动播放许可
  void _cancelRound() {
    final round = _round;
    if (round == null) return;
    round.timer?.cancel();
    _round = null;
    if (!identical(round, _standaloneRound)) _endLoad(round);
  }

  void _finishRound(_Round round) {
    round.timer?.cancel();
    if (identical(_round, round)) {
      _round = null;
    }
    _endLoad(round);
  }

  void _endLoad(_Round round) {
    final load = round.load;
    round.load = null;
    if (load != null) shutdownTimerService.endLoad(load);
  }

  /// 用户手动播放：解除此前的禁止（定时关闭、停止播放、打断），重新登记，
  /// 之后的停止播放、打断仍能撤销本轮起播
  void _allowPlay(_Round round) {
    _endLoad(round);
    final load = round.load = shutdownTimerService.beginLoad();
    round
      ..autoplay = null
      ..permits = () => shutdownTimerService.canAutoplay(load);
  }

  /// 共同起播只因暂缓（音频打断等）未能起播时登记的待恢复：暂缓解除后自动继续，
  /// 停止播放（拔出耳机、定时关闭）、新的轮次或页面变化时作废
  ShutdownLoad? _deferred;

  /// 本轮仍要播放、只因暂缓不能起播时转为等待暂缓解除，在结束本轮前调用；返回
  /// 是否已转为等待
  bool _defer(_Round round) {
    final load = round.load;
    if (_closed ||
        !round.intendsPlay ||
        load == null ||
        !shutdownTimerService.isHeld(load) ||
        !(round.autoplay?.call() ?? true)) {
      return false;
    }
    _dropDeferred();
    _deferred = shutdownTimerService.beginLoad(from: load);
    return true;
  }

  void _dropDeferred() {
    final load = _deferred;
    _deferred = null;
    if (load != null) shutdownTimerService.endLoad(load);
  }

  /// 暂缓解除后按页面原有方式继续播放，经播放前接管重新共同起播
  void _resumeDeferred() {
    final load = _deferred;
    if (load == null) return;
    if (shutdownTimerService.canAutoplay(load)) {
      _dropDeferred();
      if (!(_loadedPlayer?.state.playing ?? true)) {
        _target?.resume();
      }
    } else if (!shutdownTimerService.isHeld(load)) {
      // 已被停止播放作废
      _dropDeferred();
    }
  }

  void _advance(_Round round) {
    if (!identical(_round, round)) return;
    switch (round.phase) {
      case _Phase.loading:
        if (round.selfLoaded && round.loading.isEmpty) {
          _prepare(round);
        }
      case _Phase.preparing:
        if (round.selfReady && round.preparing.isEmpty) {
          _start(round);
        }
      case _Phase.starting:
        break;
    }
  }

  /// 未及时响应的跟随端不再等待，之后自行跳转加入
  void _skipPeers(_Round round, Set<LinkConnection> pending) {
    round.participants.removeAll(pending);
    pending.clear();
  }

  void _onLoadTimeout(_Round round) {
    if (!identical(_round, round)) return;
    if (!round.selfLoaded) {
      // 本机加载过慢：不再等待共同起播，加载完成后按播放意图自行播放，
      // 跟随端按播放进度跳转加入
      _standalone(round);
      return;
    }
    _skipPeers(round, round.loading);
    _advance(round);
  }

  void _onPrepareTimeout(_Round round) {
    if (!identical(_round, round)) return;
    _skipPeers(round, round.preparing);
    _advance(round);
  }

  /// 本机与各跟随端暂停并定位到本机当前位置，等待就绪；跟随端先于本机等待定位
  /// 完成就暂停，已知新位置 [hint] 时同时预先定位
  Future<void> _prepare(_Round round, {int? hint}) async {
    round
      ..phase = _Phase.preparing
      ..seeks = _userSeeks
      ..timer?.cancel();
    bool isCurrent() => identical(_round, round);
    final target = _target;
    final player = _loadedPlayer;
    if (target == null || player == null) {
      _cancelRound();
      return;
    }
    _attach(player);
    final pause = {'t': LinkMessageType.pause, 'pos': ?hint};
    for (final peer in round.participants) {
      peer.send(pause);
    }
    if (player.state.playing) {
      _expectPlaying = false;
      await target.pause();
    }
    final pos = await LinkedPlayer.waitLoaded(player, isCurrent);
    if (pos == null) return;
    round
      ..position = pos
      ..preparing.addAll(round.participants)
      ..timer = Timer(_prepareTimeout, () => _onPrepareTimeout(round));
    final prepare = {
      't': LinkMessageType.prepare,
      'round': round.id,
      'cid': _content!.cid,
      'pos': pos,
    };
    for (final peer in round.participants) {
      peer.send(prepare);
    }
    // 页面在发起定位时同步登记，本轮自身的定位不计为拖动
    _ownSeek = true;
    final seeking = target.seek(Duration(microseconds: pos));
    _ownSeek = false;
    await seeking;
    if (!await LinkedPlayer.waitReady(player, pos, isCurrent)) return;
    round.selfReady = true;
    _advance(round);
  }

  void _start(_Round round) {
    round.timer?.cancel();
    if (!round.intendsPlay || !(round.permits?.call() ?? true)) {
      // 只因打断等暂缓时，暂缓解除后自动继续
      _defer(round);
      _finishRound(round);
      // 未参与本轮的跟随端也定位到暂停位置
      if (_loadedPlayer case final player?) {
        _broadcastPause(player);
      }
      return;
    }
    final player = _loadedPlayer;
    if (player == null) {
      _cancelRound();
      return;
    }
    round.phase = _Phase.starting;
    final at = LinkClock.nowUs + _startLeadUs;
    final start = {
      't': LinkMessageType.start,
      'round': round.id,
      'at': at,
      'rate': player.state.rate,
    };
    for (final peer in round.participants) {
      peer.send(start);
    }
    round.timer = LinkedPlayer.scheduleAt(at, () {
      if (!identical(_round, round)) return;
      if (round.intendsPlay && seekTogether()) {
        if (_loadedPlayer case final player?
            when identical(player, _player) && _movedFrom(round, player)) {
          // 约定起播期间拖动了进度：作废本次起播，按最新位置重新共同就绪
          _reprepare(round, hint: LinkedPlayer.timePos(player));
          return;
        }
      }
      final permitted = round.permits?.call() ?? true;
      if (!permitted) _defer(round);
      _finishRound(round);
      if (!round.intendsPlay) return;
      final target = _target;
      final player = _loadedPlayer;
      if (target == null || player == null) return;
      if (!permitted) {
        // 约定时刻前停止播放（拔出耳机）或被打断：跟随端收到暂停后作废其定时起播
        if (_active) _broadcastPause(player);
        return;
      }
      _expectPlaying = true;
      _lastPosition = null;
      _stall = 0;
      final moved = _movedFrom(round, player);
      target.play();
      if (moved && _active) {
        // 追赶方式下约定起播期间拖动了进度：跟随端已按旧位置起播，跳转对齐
        _seekAt = LinkClock.nowUs;
        _transport.broadcast({
          't': LinkMessageType.seek,
          'pos': ?LinkedPlayer.timePos(player),
        });
      }
    });
  }

  /// 本机已离开本轮的就绪位置（定位就绪、约定起播期间拖动了进度）：本轮开始定位
  /// 后页面又发起了定位（含尚未完成的），或位置已偏离
  bool _movedFrom(_Round round, Player player) {
    if (round.seeks != _userSeeks) return true;
    final position = round.position;
    if (position == null || player.getProperty('seeking') == 'yes') {
      return false;
    }
    final pos = LinkedPlayer.timePos(player);
    return pos != null && (pos - position).abs() > _seekJumpUs;
  }

  /// 定位就绪（两端一起对齐时含约定起播）期间本机拖动了进度：作废旧的定位，
  /// 按最新位置重新就绪
  void _reprepare(_Round old, {int? hint}) {
    final round = _beginRound(
      intendsPlay: old.intendsPlay,
      selfLoaded: true,
      loading: const [],
      inherit: old,
    );
    _prepare(round, hint: hint);
  }

  /// 同一内容共同暂停后重新共同起播；没有在线的跟随端时本机照常播放，
  /// 跟随端恢复后自行跳转加入
  /// 返回是否开始了共同起播
  bool _resync({required bool intendsPlay, int? hint}) {
    final player = _loadedPlayer;
    // 不支持联动的内容不共同起播
    if (!_active || player == null || _content == null) return false;
    final round = _beginRound(
      intendsPlay: intendsPlay,
      selfLoaded: true,
      loading: const [],
    );
    if (round.participants.isEmpty) {
      _cancelRound();
      _expectPlaying = player.state.playing;
      _lastPosition = null;
      return false;
    }
    _prepare(round, hint: hint);
    return true;
  }

  /// 本机开始播放的操作（播放按钮、手势、媒体控制、快捷键等），在播放器出声之前
  /// 调用：需要与跟随端共同起播时不直接播放，改为共同起播，到约定时刻才出声；
  /// 返回是否已接管。联动自身的起播（已预期播放）、没有需要等待的跟随端、播完后
  /// 重播时不接管，照常立即播放
  bool takePlay(LinkedTarget target) {
    if (!_active || _expectPlaying || !identical(target, _target)) {
      return false;
    }
    final player = _loadedPlayer;
    if (player == null || player.state.playing || player.state.completed) {
      return false;
    }
    final round = _round;
    if (round != null) {
      // 本机已加载、等待跟随端加载期间照常播放
      if (round.phase == _Phase.loading && round.selfLoaded) return false;
      round.intendsPlay = true;
      _allowPlay(round);
      return true;
    }
    if (_standaloneRound != null) return false;
    return _resync(intendsPlay: true);
  }

  /// 把本机当前的内容发给尚未收到的跟随端：新内容尚在加载时加入本轮共同起播；
  /// 本机已在播放或暂停时不打断本机，跟随端加载后自行跳转加入
  void _sendContent() {
    if (!_active || _content == null) return;
    final waiting = [
      for (final MapEntry(key: peer, value: state) in _peers.entries)
        if (state.needsContent) peer,
    ];
    if (waiting.isEmpty) return;
    final round = _round;
    final Map<String, Object?> open;
    if (round != null) {
      // 定位、起播期间稍后再发
      if (round.phase != _Phase.loading) return;
      round
        ..participants.addAll(waiting)
        ..loading.addAll(waiting);
      open = _open(round.id);
    } else {
      final player = _loadedPlayer;
      if (player == null) return;
      _attach(player);
      // 没有跟随端期间未跟踪本机的播放状态
      _expectPlaying = player.state.playing;
      open = _open(_roundId);
    }
    for (final peer in waiting) {
      _peers[peer]!.needsContent = false;
      peer.send(open);
    }
  }

  /// 本机暂停时把暂停位置发给刚加载完的跟随端；播放时跟随端按播放进度加入
  void _sendState(LinkConnection peer) {
    final player = _loadedPlayer;
    if (_expectPlaying || player == null || player.state.playing) return;
    if (LinkedPlayer.timePos(player) case final pos?) {
      peer.send({'t': LinkMessageType.pause, 'pos': pos});
    }
  }

  void _broadcastPause(Player player) {
    final pos = LinkedPlayer.timePos(player);
    if (pos == null) return;
    _pausedPos = pos;
    _transport.broadcast({'t': LinkMessageType.pause, 'pos': pos});
  }

  // 本机播放器

  void _attach(Player player) {
    if (_closed) return;
    if (!identical(player, _player)) {
      _detach();
      _player = player;
      _subscriptions.addAll([
        player.stream.playing.listen(_onPlaying),
        player.stream.position.listen(_onPosition),
      ]);
    }
    if (!_synced && _active && _target?.kind == LinkedKind.video) {
      _synced = true;
      LinkedPlayer.setVideoSync(player, linked: true);
    }
  }

  /// 不再联动当前播放器（换播放器、页面关闭等）：先恢复其同步方式
  void _detach() {
    _restorePlayer();
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _subscriptions.clear();
    _player = null;
    _lastPosition = null;
  }

  void _restorePlayer() {
    final player = _player;
    if (_synced && player != null) {
      LinkedPlayer.setVideoSync(player, linked: false);
    }
    _synced = false;
  }

  /// 播放器的播放状态与预期不符时，按用户或页面的播放、暂停操作同步
  void _onPlaying(bool playing) {
    if (playing == _expectPlaying || !_active) return;
    final target = _target;
    final player = _loadedPlayer;
    if (target == null || player == null || !identical(player, _player)) {
      return;
    }
    final round = _round;
    if (playing) {
      if (round == null) {
        _resync(intendsPlay: true);
        return;
      }
      round.intendsPlay = true;
      _allowPlay(round);
      if (round.phase == _Phase.loading && round.selfLoaded) {
        // 等待跟随端加载期间本机照常播放
        _expectPlaying = true;
        return;
      }
      target.pause();
    } else {
      _expectPlaying = false;
      round?.intendsPlay = false;
      if (!player.state.completed) {
        _broadcastPause(player);
      }
    }
  }

  void _onPosition(Duration position) {
    if (!_expectPlaying || _round != null || !_active) return;
    final player = _player;
    if (player == null || !player.state.playing) return;
    final now = LinkClock.nowUs;
    final pos = position.inMicroseconds;
    final last = _lastPosition;
    _lastPosition = (pos: pos, at: now);
    if (last == null) return;
    final expected = last.pos + (now - last.at) * player.state.rate;
    if ((pos - expected).abs() > _seekJumpUs) {
      _seekAt = now;
      _stall = 0;
      if (seekTogether()) {
        // 两端共同暂停、定位到新位置后共同起播
        _resync(intendsPlay: true, hint: pos);
        return;
      }
      // 本机在新位置继续播放，跟随端立即预先定位，收到新进度后跳转对齐
      _transport.broadcast({'t': LinkMessageType.seek, 'pos': pos});
    }
  }

  void _tick(Timer _) {
    _resumeDeferred();
    if (!_active || _content == null) return;
    final target = _target;
    if (target == null || !target.isActive) {
      // 页面已不再持有播放器
      if (_round == null) {
        _content = null;
        _target = null;
        _expectPlaying = false;
        _detach();
        _transport.broadcast(const {'t': LinkMessageType.stop});
      }
      return;
    }
    _sendContent();
    final player = _loadedPlayer;
    if (player == null) return;
    if (_round case final round?) {
      if ((round.phase == _Phase.preparing ||
              (round.phase == _Phase.starting && seekTogether())) &&
          identical(player, _player) &&
          _movedFrom(round, player)) {
        _reprepare(round, hint: LinkedPlayer.timePos(player));
      }
      return;
    }
    _attach(player);
    final state = player.state;
    if (_expectPlaying && state.playing) {
      _pausedPos = null;
      if (state.buffering) {
        if (LinkClock.nowUs - _seekAt > _seekGraceUs &&
            ++_stall >= _stallTicks) {
          _stall = 0;
          _resync(intendsPlay: true);
        }
        return;
      }
      _stall = 0;
      if (LinkedPlayer.sample(player) case final sample?) {
        _transport.broadcast({
          't': LinkMessageType.position,
          'cid': _content!.cid,
          'pos': sample.pos,
          'at': sample.at,
          'rate': state.rate,
        });
      }
    } else if (!_expectPlaying && !state.playing && !state.completed) {
      final pos = LinkedPlayer.timePos(player);
      final paused = _pausedPos;
      if (pos != null &&
          (paused == null || (pos - paused).abs() > _pausedMoveUs)) {
        _broadcastPause(player);
      }
    }
  }

  // 跟随端

  void _onConnected(LinkConnection peer) {
    _peers[peer] = _PeerState(peer.address);
    _notifyPeers();
  }

  void _onHello(LinkConnection peer, _PeerState state, LinkMessage message) {
    final id = message['id'];
    final name = message['name'];
    if (id is! String) return;
    state
      ..id = id
      ..name = name is String && name.isNotEmpty ? name : peer.address;
    // 同一设备重新连接时取代旧连接
    final wasOffline = _offline.remove(id) != null;
    var replacing = false;
    for (final MapEntry(key: other, value: otherState) in _peers.entries
        .toList()) {
      if (!identical(other, peer) && otherState.id == id) {
        otherState.replaced = true;
        replacing = true;
        other.close();
      }
    }
    if (!replacing) {
      SmartDialog.showToast(
        '联动播放：${state.name} ${wasOffline ? '已重新连接' : '已连接'}',
      );
    }
    peer
      ..send(_syncMessage)
      ..send(_volumeMessage);
    if (message['sync'] case final bool on when on != syncOn()) {
      onSyncRequest(on);
    }
    // 同步已关闭时各端互不影响
    if (message['stopAll'] == true && syncOn()) {
      pauseAll();
    }
    if (_content == null) {
      // 断开期间本机已停止：跟随端不再自行播放
      peer.send(const {'t': LinkMessageType.stop});
    }
    state.needsContent = true;
    _sendContent();
    _notifyPeers();
  }

  void _onMessage(LinkConnection peer, LinkMessage message) {
    final state = _peers[peer];
    if (state == null) return;
    if (message['t'] == LinkMessageType.hello) {
      _onHello(peer, state, message);
      return;
    }
    if (state.id == null) return;
    final id = message['round'];
    final round = _round;
    switch (message['t']) {
      case LinkMessageType.sync:
        if (message['on'] case final bool on) {
          onSyncRequest(on);
        }
      case LinkMessageType.stopAll:
        if (syncOn()) pauseAll();
      case LinkMessageType.want:
        if (round == null || !round.participants.contains(peer)) {
          state.needsContent = true;
          _sendContent();
        }
      case LinkMessageType.loaded:
        if (round != null) {
          if (round.id == id && round.loading.remove(peer)) {
            _advance(round);
          }
        } else {
          _sendState(peer);
        }
      case LinkMessageType.ready:
        if (round != null &&
            round.id == id &&
            round.preparing.remove(peer)) {
          _advance(round);
        }
      case LinkMessageType.resync:
        // 迟到的旧内容请求不打断当前内容
        if (round == null &&
            _expectPlaying &&
            message['cid'] == _content?.cid) {
          _resync(intendsPlay: true);
        }
      case LinkMessageType.report:
        final drift = message['drift'];
        final rtt = message['rtt'];
        final volume = message['volume'];
        final reason = message['reason'];
        if (message['offset'] case final int offset) {
          final requested = state.setOffsetUs;
          if (requested == null ||
              offset == requested ||
              LinkClock.nowUs - state.setOffsetAt >= _offsetEchoUs) {
            state
              ..offsetUs = offset
              ..setOffsetUs = null;
          }
        }
        state
          ..state =
              LinkedPeerState.values.asNameMap()[message['state']] ??
              LinkedPeerState.idle
          ..reason = reason is String ? reason : null
          ..driftMs = drift is num ? drift.toDouble() : null
          ..rttMs = rtt is num ? rtt.toDouble() : null
          ..volume = LinkedVolume.fromJson(volume) ?? state.volume;
        _notifyPeers();
    }
  }

  void _onDisconnected(LinkConnection peer) {
    final state = _peers.remove(peer);
    if (state != null && state.id != null && !state.replaced) {
      _offline[state.id!] = state.info(state: LinkedPeerState.offline);
      SmartDialog.showToast('联动播放：${state.name} 已离线');
    }
    _notifyPeers();
    final round = _round;
    if (round != null) {
      round
        ..participants.remove(peer)
        ..loading.remove(peer)
        ..preparing.remove(peer);
    }
    if (hasPeers) {
      if (round != null) _advance(round);
      return;
    }
    // 没有跟随端时恢复为普通播放
    _restorePlayer();
    _standalone(round);
  }

  void _notifyPeers() {
    onPeersChanged([
      for (final state in _peers.values)
        if (!state.replaced) state.info(),
      ..._offline.values,
    ]);
  }
}
