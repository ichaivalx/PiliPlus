import 'dart:async';

import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/services/linked_playback/clock.dart';
import 'package:PiliPlus/services/linked_playback/models.dart';
import 'package:PiliPlus/services/linked_playback/player_access.dart';
import 'package:PiliPlus/services/linked_playback/protocol.dart';
import 'package:PiliPlus/services/linked_playback/transport.dart';
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

  bool selfLoaded;
  bool selfReady = false;
  _Phase phase = _Phase.loading;
  int? position;

  /// 参与本轮的跟随端，超时未响应的移出
  final Set<LinkConnection> participants;
  final Set<LinkConnection> loading;
  final Set<LinkConnection> preparing = {};
  Timer? timer;
}

class _PeerState {
  /// 尚未收到本机当前播放的内容
  bool needsContent = true;

  /// 未及时响应而被跳过的轮次，之后回报时重新共同起播
  int? missedRound;

  double? driftMs;
  double? rttMs;
}

/// 主控：本机播放的内容与播放操作同步给所有跟随端
class LeaderSession {
  LeaderSession({
    required this.offsetMs,
    required this.onPeersChanged,
  });

  static const _tickInterval = Duration(milliseconds: 250);
  static const _heartbeatUs = 2000000;
  static const _peerTimeoutUs = 6000000;
  static const _loadTimeout = Duration(seconds: 20);
  static const _prepareTimeout = Duration(seconds: 10);

  /// 约定起播时刻距发出指令的时间，需大于网络单程延迟
  static const _startLeadUs = 350000;

  /// 播放中位置的跳变超过此值视为拖动进度
  static const _seekJumpUs = 1000000;

  /// 暂停时位置变化超过此值时同步给跟随端
  static const _pausedMoveUs = 150000;

  /// 连续卡顿的检查次数，达到后重新共同起播
  static const _stallTicks = 3;

  final int Function() offsetMs;
  final void Function(List<LinkedPeerInfo>) onPeersChanged;

  late final _transport = LeaderTransport(
    onConnected: _onConnected,
    onMessage: _onMessage,
    onDisconnected: _onDisconnected,
  );
  final Map<LinkConnection, _PeerState> _peers = {};
  Timer? _ticker;

  /// 本机当前播放的可联动内容
  LinkedContent? _content;
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
  int _lastHeartbeat = 0;

  bool get _hasPeers => _transport.connections.isNotEmpty;

  Future<void> start() async {
    await _transport.start();
    _ticker = Timer.periodic(_tickInterval, _tick);
  }

  void dispose() {
    _ticker?.cancel();
    _cancelRound();
    _transport
      ..broadcast(const {'t': LinkMessageType.stop})
      ..dispose();
    _peers.clear();
    _restorePlayer();
    _detach();
  }

  void updateOffset() => _transport.broadcast(_config);

  Map<String, Object?> get _config => {
    't': LinkMessageType.config,
    'offset': offsetMs(),
  };

  PlPlayerController? get _controller => LinkedPlayer.withContent(_content?.cid);

  // 页面接入

  LinkedLoad? gateLoad(LinkedContent? content, {required bool autoplay}) {
    _content = content;
    if (!_hasPeers) return null;
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
      intendsPlay: autoplay,
      selfLoaded: false,
      loading: _transport.connections,
    );
    _transport.broadcast(_open(round));
    return LinkedLoad(onLoaded: () => _onSelfLoaded(round));
  }

  Map<String, Object?> _open(_Round round) => {
    't': LinkMessageType.open,
    'round': round.id,
    'content': _content!.toJson(),
  };

  void _onSelfLoaded(_Round round) {
    if (!identical(_round, round)) return;
    final controller = _controller;
    if (controller == null) {
      // 加载失败
      _cancelRound();
      _transport.broadcast(const {'t': LinkMessageType.stop});
      return;
    }
    _attach(controller);
    round.selfLoaded = true;
    _advance(round);
  }

  // 轮次

  _Round _beginRound({
    required bool intendsPlay,
    required bool selfLoaded,
    required Iterable<LinkConnection> loading,
  }) {
    _cancelRound();
    final round = _round = _Round(
      ++_roundId,
      intendsPlay: intendsPlay,
      selfLoaded: selfLoaded,
      participants: _transport.connections.toSet(),
      loading: loading.toSet(),
    );
    round.timer = Timer(_loadTimeout, () => _onLoadTimeout(round));
    return round;
  }

  void _cancelRound() {
    _round?.timer?.cancel();
    _round = null;
  }

  void _finishRound(_Round round) {
    round.timer?.cancel();
    if (identical(_round, round)) {
      _round = null;
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

  void _skipPeers(_Round round, Set<LinkConnection> pending) {
    for (final peer in pending) {
      round.participants.remove(peer);
      _peers[peer]?.missedRound = round.id;
    }
    pending.clear();
  }

  void _onLoadTimeout(_Round round) {
    if (!identical(_round, round)) return;
    if (!round.selfLoaded) {
      _cancelRound();
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

  /// 本机与各跟随端暂停并定位到本机当前位置，等待就绪
  Future<void> _prepare(_Round round) async {
    round
      ..phase = _Phase.preparing
      ..timer?.cancel();
    bool isCurrent() => identical(_round, round);
    final controller = _controller;
    if (controller == null) {
      _cancelRound();
      return;
    }
    final player = _attach(controller);
    if (player.state.playing) {
      _expectPlaying = false;
      await controller.pause(isInterrupt: true);
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
    await controller.seek(Duration(microseconds: pos));
    if (!await LinkedPlayer.waitReady(player, pos, isCurrent)) return;
    round.selfReady = true;
    _advance(round);
  }

  void _start(_Round round) {
    round.timer?.cancel();
    if (!round.intendsPlay) {
      _pausedPos = round.position;
      _finishRound(round);
      return;
    }
    final controller = _controller;
    if (controller == null) {
      _cancelRound();
      return;
    }
    round.phase = _Phase.starting;
    final at = LinkClock.nowUs + _startLeadUs;
    final start = {
      't': LinkMessageType.start,
      'round': round.id,
      'at': at,
      'rate': controller.videoPlayerController!.state.rate,
    };
    for (final peer in round.participants) {
      peer.send(start);
    }
    round.timer = LinkedPlayer.scheduleAt(at, () {
      if (!identical(_round, round)) return;
      _finishRound(round);
      final controller = _controller;
      if (controller == null) return;
      _expectPlaying = true;
      _lastPosition = null;
      _stall = 0;
      controller.play();
    });
  }

  /// 同一内容重新共同起播
  void _resync({required bool intendsPlay}) {
    if (!_hasPeers || _controller == null) return;
    _prepare(
      _beginRound(
        intendsPlay: intendsPlay,
        selfLoaded: true,
        loading: const [],
      ),
    );
  }

  /// 把本机当前的内容发给尚未收到的跟随端，本机已加载时在其加载期间照常播放
  void _sendContent() {
    final waiting = [
      for (final MapEntry(key: peer, value: state) in _peers.entries)
        if (state.needsContent) peer,
    ];
    if (waiting.isEmpty || _content == null) return;
    var round = _round;
    if (round != null && round.phase == _Phase.loading) {
      round
        ..participants.addAll(waiting)
        ..loading.addAll(waiting);
    } else {
      final controller = _controller;
      if (controller == null) return;
      final player = _attach(controller);
      final intendsPlay = round?.intendsPlay ?? player.state.playing;
      if (round == null) {
        _expectPlaying = player.state.playing;
      }
      round = _beginRound(
        intendsPlay: intendsPlay,
        selfLoaded: true,
        loading: waiting,
      );
    }
    final open = _open(round);
    for (final peer in waiting) {
      _peers[peer]!.needsContent = false;
      peer.send(open);
    }
  }

  void _broadcastPause(Player player) {
    final pos = LinkedPlayer.timePos(player);
    if (pos == null) return;
    _pausedPos = pos;
    _transport.broadcast({'t': LinkMessageType.pause, 'pos': pos});
  }

  // 本机播放器

  Player _attach(PlPlayerController controller) {
    final player = controller.videoPlayerController!;
    if (!identical(player, _player)) {
      _detach();
      _player = player;
      _subscriptions.addAll([
        player.stream.playing.listen(_onPlaying),
        player.stream.position.listen(_onPosition),
      ]);
    }
    if (!_synced && _hasPeers) {
      _synced = true;
      LinkedPlayer.setVideoSync(player, linked: true);
    }
    return player;
  }

  void _detach() {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _subscriptions.clear();
    _player = null;
    _synced = false;
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
    if (playing == _expectPlaying || !_hasPeers) return;
    final controller = _controller;
    if (controller == null) return;
    final player = controller.videoPlayerController!;
    if (!identical(player, _player)) return;
    final round = _round;
    if (playing) {
      if (round == null) {
        _resync(intendsPlay: true);
        return;
      }
      round.intendsPlay = true;
      if (round.phase == _Phase.loading && round.selfLoaded) {
        // 等待跟随端加载期间本机照常播放
        _expectPlaying = true;
        return;
      }
      controller.pause(isInterrupt: true);
    } else {
      _expectPlaying = false;
      round?.intendsPlay = false;
      if (!player.state.completed) {
        _broadcastPause(player);
      }
    }
  }

  void _onPosition(Duration position) {
    if (!_expectPlaying || _round != null || !_hasPeers) return;
    final player = _player;
    if (player == null || !player.state.playing) return;
    final now = LinkClock.nowUs;
    final pos = position.inMicroseconds;
    final last = _lastPosition;
    _lastPosition = (pos: pos, at: now);
    if (last == null) return;
    final expected = last.pos + (now - last.at) * player.state.rate;
    if ((pos - expected).abs() > _seekJumpUs) {
      _resync(intendsPlay: true);
    }
  }

  void _tick(Timer _) {
    final now = LinkClock.nowUs;
    for (final peer in _transport.connections.toList()) {
      if (now - peer.lastReceived > _peerTimeoutUs) {
        peer.close();
      }
    }
    if (!_hasPeers) return;
    if (now - _lastHeartbeat > _heartbeatUs) {
      _lastHeartbeat = now;
      _transport.broadcast(const {'t': LinkMessageType.heartbeat});
    }
    if (_content == null) return;
    _sendContent();
    final controller = _controller;
    if (controller == null) {
      // 播放器已销毁，本机不再播放该内容
      if (_round == null &&
          PlPlayerController.instance?.videoPlayerController == null) {
        _content = null;
        _expectPlaying = false;
        _detach();
        _transport.broadcast(const {'t': LinkMessageType.stop});
      }
      return;
    }
    if (_round != null) return;
    final player = _attach(controller);
    final state = player.state;
    if (_expectPlaying && state.playing) {
      _pausedPos = null;
      if (state.buffering) {
        if (++_stall >= _stallTicks) {
          _stall = 0;
          _resync(intendsPlay: true);
        }
        return;
      }
      _stall = 0;
      if (LinkedPlayer.sample(player) case final sample?) {
        _transport.broadcast({
          't': LinkMessageType.position,
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
    _peers[peer] = _PeerState();
    _notifyPeers();
    SmartDialog.showToast('联动播放：跟随端 ${peer.address} 已连接');
  }

  void _onMessage(LinkConnection peer, LinkMessage message) {
    final state = _peers[peer];
    if (state == null) return;
    final id = message['round'];
    final round = _round;
    switch (message['t']) {
      case LinkMessageType.hello:
        peer.send(_config);
        _sendContent();
      case LinkMessageType.loaded:
        if (round != null) {
          if (round.id == id && round.loading.remove(peer)) {
            _advance(round);
          }
        } else if (id == _roundId) {
          // 跟随端自行重新加载或此前超时，重新共同起播
          _resync(intendsPlay: _expectPlaying);
        }
      case LinkMessageType.ready:
        if (round != null) {
          if (round.id == id && round.preparing.remove(peer)) {
            _advance(round);
          }
        } else if (id == _roundId && state.missedRound == id) {
          _resync(intendsPlay: _expectPlaying);
        }
      case LinkMessageType.resync:
        if (round == null && _expectPlaying) {
          _resync(intendsPlay: true);
        }
      case LinkMessageType.report:
        final drift = message['drift'];
        final rtt = message['rtt'];
        state
          ..driftMs = drift is num ? drift.toDouble() : null
          ..rttMs = rtt is num ? rtt.toDouble() : null;
        _notifyPeers();
    }
  }

  void _onDisconnected(LinkConnection peer) {
    _peers.remove(peer);
    _notifyPeers();
    SmartDialog.showToast('联动播放：跟随端 ${peer.address} 已断开');
    final round = _round;
    if (round != null) {
      round
        ..participants.remove(peer)
        ..loading.remove(peer)
        ..preparing.remove(peer);
    }
    if (_hasPeers) {
      if (round != null) _advance(round);
      return;
    }
    // 没有跟随端时恢复为普通播放
    _cancelRound();
    _restorePlayer();
    final controller = _controller;
    if (round != null &&
        round.intendsPlay &&
        controller != null &&
        !controller.videoPlayerController!.state.playing) {
      controller.play();
    }
  }

  void _notifyPeers() {
    onPeersChanged([
      for (final MapEntry(key: peer, value: state) in _peers.entries)
        LinkedPeerInfo(
          address: peer.address,
          driftMs: state.driftMs,
          rttMs: state.rttMs,
        ),
    ]);
  }
}
