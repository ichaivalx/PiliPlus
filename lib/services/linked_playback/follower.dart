import 'dart:async';
import 'dart:math' show max;

import 'package:PiliPlus/models_new/video/video_detail/episode.dart';
import 'package:PiliPlus/pages/video/controller.dart';
import 'package:PiliPlus/pages/video/introduction/ugc/controller.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/services/linked_playback/clock.dart';
import 'package:PiliPlus/services/linked_playback/models.dart';
import 'package:PiliPlus/services/linked_playback/player_access.dart';
import 'package:PiliPlus/services/linked_playback/protocol.dart';
import 'package:PiliPlus/services/linked_playback/transport.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';

/// 跟随端：按主控打开内容、定位、起播，并持续追齐主控的播放进度
class FollowerSession {
  FollowerSession({
    required this.leader,
    required this.driftMs,
    required this.rttMs,
  });

  static const _tickInterval = Duration(milliseconds: 250);
  static const _reportUs = 1000000;
  static const _leaderTimeoutUs = 6000000;

  /// 起播后音频输出稳定前不做校正
  static const _settleUs = 1500000;

  static const _interceptWindow = 8;
  static const _driftWindow = 4;

  /// 偏差超过 [_enterMs] 开始微调倍速，回到 [_exitMs] 以内停止
  static const _enterMs = 15.0;
  static const _exitMs = 4.0;

  /// 偏差超过此值时请求主控重新共同起播
  static const _hardMs = 400.0;

  /// 微调倍速按偏差在约此时长内追平，且不超过 [_maxAdjust]
  static const _tauSeconds = 2.0;
  static const _maxAdjust = 0.04;
  static const _adjustStep = 0.0025;

  static const _resyncIntervalUs = 10000000;
  static const _stallTicks = 4;

  final RxnString leader;
  final RxnDouble driftMs;
  final RxnDouble rttMs;

  late final _transport = FollowerTransport(
    onConnected: _onConnected,
    onMessage: _onMessage,
    onDisconnected: _onDisconnected,
  );
  ClockSync get _clock => _transport.clock;
  Timer? _ticker;

  /// 主控本轮播放的内容
  LinkedContent? _content;
  int _round = 0;

  /// 内容已在本机加载
  bool _loaded = false;
  int _loadToken = 0;

  /// 待定位的轮次与主控位置
  int? _pendingRound;
  int? _pendingPos;
  int? _readyRound;

  /// 主控的新指令使进行中的定位、定时起播作废
  int _generation = 0;
  bool _shouldPlay = false;
  Timer? _startTimer;
  int _offsetUs = 0;

  /// 主控的播放进度模型：位置 = 截距 + 倍速 × 主控时刻
  double _rate = 1.0;
  final List<int> _intercepts = [];
  final List<double> _drifts = [];
  bool _correcting = false;
  double _factor = 1.0;
  Player? _speedPlayer;
  double? _appliedSpeed;
  Player? _syncedPlayer;

  int _settleUntil = 0;
  int _lastResync = -_resyncIntervalUs;
  int _lastReport = 0;
  int _stall = 0;

  bool get isConnected => _transport.isConnected;

  PlPlayerController? get _controller => LinkedPlayer.withContent(_content?.cid);

  Future<void> start() async {
    await _transport.start();
    _ticker = Timer.periodic(_tickInterval, _tick);
  }

  void dispose() {
    _ticker?.cancel();
    _generation++;
    _halt();
    _release();
    _transport.dispose();
    leader.value = null;
    driftMs.value = null;
    rttMs.value = null;
  }

  // 页面接入

  /// 主控有内容时本机的加载都不自动播放；与主控的内容一致时加载后回报
  LinkedLoad? gateLoad(LinkedContent? content) {
    final current = _content;
    if (!isConnected || current == null) {
      return null;
    }
    if (content?.cid != current.cid) {
      return LinkedLoad(onLoaded: () {});
    }
    final token = ++_loadToken;
    _halt();
    _loaded = false;
    final pendingPos = _pendingPos;
    return LinkedLoad(
      position: pendingPos == null
          ? null
          : Duration(microseconds: max(0, pendingPos - _offsetUs)),
      onLoaded: () {
        if (token != _loadToken || _controller == null) return;
        _loaded = true;
        _transport.send({'t': LinkMessageType.loaded, 'round': _round});
        if (_pendingRound != null) {
          _prepare();
        }
      },
    );
  }

  // 连接

  void _onConnected() {
    _transport.send(const {'t': LinkMessageType.hello});
    leader.value = _transport.connection?.address;
    SmartDialog.showToast('联动播放：已连接主控 ${leader.value}');
  }

  void _onDisconnected() {
    _generation++;
    _loadToken++;
    _halt();
    _release();
    _content = null;
    _loaded = false;
    _pendingRound = null;
    _pendingPos = null;
    _readyRound = null;
    leader.value = null;
    driftMs.value = null;
    rttMs.value = null;
    SmartDialog.showToast('联动播放：与主控的连接已断开');
  }

  void _onMessage(LinkMessage message) {
    switch (message['t']) {
      case LinkMessageType.config:
        if (message['offset'] case final num offset) {
          _offsetUs = (offset * 1000).round();
        }
      case LinkMessageType.open:
        final round = message['round'];
        final content = LinkedContent.fromJson(message['content']);
        if (round is! int || content == null) return;
        _round = round;
        _generation++;
        _loadToken++;
        _halt();
        _content = content;
        _pendingRound = null;
        _pendingPos = null;
        _readyRound = null;
        if (_controller != null) {
          _loaded = true;
          _transport.send({'t': LinkMessageType.loaded, 'round': round});
        } else {
          _loaded = false;
          _openContent(content);
        }
      case LinkMessageType.prepare:
        final round = message['round'];
        final pos = message['pos'];
        if (round is! int || pos is! int || message['cid'] != _content?.cid) {
          return;
        }
        _round = round;
        _generation++;
        _halt();
        _pendingRound = round;
        _pendingPos = pos;
        _readyRound = null;
        if (_loaded) {
          _prepare();
        }
      case LinkMessageType.start:
        final round = message['round'];
        final at = message['at'];
        final rate = message['rate'];
        if (round is int &&
            round == _readyRound &&
            at is int &&
            rate is num &&
            _clock.isReady) {
          _scheduleStart(at, rate.toDouble());
        }
      case LinkMessageType.pause:
        _startTimer?.cancel();
        _startTimer = null;
        _shouldPlay = false;
        _resetCorrection();
        final controller = _controller;
        if (controller == null) return;
        if (controller.videoPlayerController!.state.playing) {
          controller.pause();
        }
        // 定位中时以定位为准
        if (message['pos'] case final int pos when _pendingRound == null) {
          controller.seek(Duration(microseconds: max(0, pos - _offsetUs)));
        }
      case LinkMessageType.position:
        _onLeaderPosition(message);
      case LinkMessageType.stop:
        _generation++;
        _loadToken++;
        _halt();
        _content = null;
        _loaded = false;
        _pendingRound = null;
        _pendingPos = null;
        _readyRound = null;
    }
  }

  // 内容

  /// 当前详情页可直接切换时在页内切换，否则打开新的详情页
  void _openContent(LinkedContent content) {
    final owner = PlPlayerController.playOwner;
    if (owner != null &&
        owner.type == UgcIntroController &&
        Get.isRegistered<VideoDetailController>(tag: owner.tag) &&
        Get.isRegistered<UgcIntroController>(tag: owner.tag)) {
      final detail = Get.find<VideoDetailController>(tag: owner.tag);
      if (detail.autoPlay && !detail.isPlayAll && !detail.isFileSource) {
        if (detail.cid.value != content.cid) {
          Get.find<UgcIntroController>(tag: owner.tag).onChangeEpisode(
            BaseEpisodeItem(
              aid: content.aid,
              bvid: content.bvid,
              cid: content.cid,
              cover: content.cover,
              title: content.title,
            ),
          );
        } else if (!detail.isQuerying &&
            !(PlPlayerController.instance?.processing ?? false)) {
          detail.queryVideoUrl();
        }
        return;
      }
    }
    PageUtils.toVideoPage(
      aid: content.aid,
      bvid: content.bvid,
      cid: content.cid,
      cover: content.cover,
      title: content.title,
      extraArguments: const {LinkedArgs.open: true},
    );
  }

  // 定位与起播

  Future<void> _prepare() async {
    final round = _pendingRound;
    final pos = _pendingPos;
    final controller = _controller;
    if (round == null || pos == null || controller == null) return;
    final generation = _generation;
    bool isCurrent() => generation == _generation && isConnected;
    final player = controller.videoPlayerController!;
    _link(player);
    if (player.state.playing) {
      await controller.pause(isInterrupt: true);
    }
    // 文件打开前无法定位
    if (await LinkedPlayer.waitLoaded(player, isCurrent) == null) return;
    final target = max(0, pos - _offsetUs);
    await controller.seek(Duration(microseconds: target));
    if (!await LinkedPlayer.waitReady(player, target, isCurrent)) return;
    while (!_clock.isReady) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (!isCurrent()) return;
    }
    _pendingRound = null;
    _readyRound = round;
    _transport.send({'t': LinkMessageType.ready, 'round': round});
  }

  void _scheduleStart(int leaderAt, double rate) {
    final controller = _controller;
    if (controller == null) return;
    _setRate(controller, rate);
    _resetCorrection();
    final generation = _generation;
    _startTimer?.cancel();
    _startTimer = LinkedPlayer.scheduleAt(_clock.toLocal(leaderAt), () {
      _startTimer = null;
      if (generation != _generation) return;
      final controller = _controller;
      if (controller == null) return;
      _shouldPlay = true;
      _settleUntil = LinkClock.nowUs + _settleUs;
      _stall = 0;
      controller.play();
    });
  }

  /// 停止跟随播放，保留已加载的内容
  void _halt() {
    _startTimer?.cancel();
    _startTimer = null;
    _shouldPlay = false;
    _resetCorrection();
    final controller = _controller;
    if (controller != null &&
        controller.videoPlayerController!.state.playing) {
      controller.pause();
    }
  }

  void _link(Player player) {
    if (identical(player, _syncedPlayer)) return;
    _syncedPlayer = player;
    LinkedPlayer.setVideoSync(player, linked: true);
  }

  /// 恢复播放器的同步方式与倍速
  void _release() {
    for (final player in {?_syncedPlayer, ?_speedPlayer}) {
      if (!player.disposed) {
        LinkedPlayer.setVideoSync(player, linked: false);
        LinkedPlayer.setSpeed(player, player.state.rate);
      }
    }
    _syncedPlayer = null;
    _speedPlayer = null;
    _appliedSpeed = null;
  }

  // 追齐

  void _setRate(PlPlayerController controller, double rate) {
    final changed = rate != _rate;
    _rate = rate;
    if (changed) {
      _intercepts.clear();
      _drifts.clear();
    }
    if (controller.playbackSpeed != rate) {
      controller.setPlaybackSpeed(rate).whenComplete(() {
        if (controller.videoPlayerController case final player?) {
          _applySpeed(player, force: true);
        }
      });
    }
  }

  void _onLeaderPosition(LinkMessage message) {
    final pos = message['pos'];
    final at = message['at'];
    final rate = message['rate'];
    if (pos is! int || at is! int || rate is! num) return;
    final controller = _controller;
    if (controller != null && rate.toDouble() != _rate) {
      _setRate(controller, rate.toDouble());
    }
    _intercepts.add(pos - (_rate * at).round());
    if (_intercepts.length > _interceptWindow) {
      _intercepts.removeAt(0);
    }
  }

  void _resetCorrection() {
    _intercepts.clear();
    _drifts.clear();
    _correcting = false;
    _factor = 1.0;
    if (_controller?.videoPlayerController case final player?) {
      _applySpeed(player);
    }
  }

  void _applySpeed(Player player, {bool force = false}) {
    final speed = _rate * _factor;
    final applied = _appliedSpeed;
    if (!force &&
        identical(player, _speedPlayer) &&
        applied != null &&
        (speed - applied).abs() < 0.0002) {
      return;
    }
    _speedPlayer = player;
    _appliedSpeed = speed;
    LinkedPlayer.setSpeed(player, speed);
  }

  static double _median(List<num> values) {
    final sorted = [...values]..sort();
    final middle = sorted.length ~/ 2;
    return sorted.length.isOdd
        ? sorted[middle].toDouble()
        : (sorted[middle - 1] + sorted[middle]) / 2;
  }

  /// 本机相对主控（已扣除延迟偏移）的偏差，正值表示本机超前（毫秒）
  double? _measure(Player player) {
    if (_intercepts.isEmpty || !_clock.isReady) return null;
    final sample = LinkedPlayer.sample(player);
    if (sample == null) return null;
    final leaderPos =
        _median(_intercepts) + _rate * _clock.toRemote(sample.at) - _offsetUs;
    _drifts.add((sample.pos - leaderPos) / 1000);
    if (_drifts.length > _driftWindow) {
      _drifts.removeAt(0);
    }
    return _median(_drifts);
  }

  void _requestResync(int now) {
    if (now - _lastResync < _resyncIntervalUs) return;
    _lastResync = now;
    _transport.send({'t': LinkMessageType.resync, 'round': _round});
    _resetCorrection();
  }

  double? _follow(Player player, int now) {
    if (player.state.buffering) {
      if (++_stall >= _stallTicks) {
        _stall = 0;
        _requestResync(now);
      }
      return null;
    }
    _stall = 0;
    final drift = _measure(player);
    if (drift == null || now < _settleUntil) return drift;
    final magnitude = drift.abs();
    if (magnitude > _hardMs) {
      _requestResync(now);
      return drift;
    }
    if (_correcting) {
      _correcting = magnitude >= _exitMs;
    } else {
      _correcting = magnitude > _enterMs;
    }
    // 按步长取整，减少倍速变化的次数
    _factor = _correcting
        ? 1 -
              ((drift / 1000 / _tauSeconds).clamp(-_maxAdjust, _maxAdjust) /
                          _adjustStep)
                      .round() *
                  _adjustStep
        : 1.0;
    _applySpeed(player);
    return drift;
  }

  void _tick(Timer _) {
    final connection = _transport.connection;
    if (connection == null) return;
    final now = LinkClock.nowUs;
    if (now - connection.lastReceived > _leaderTimeoutUs) {
      connection.close();
      return;
    }
    double? drift;
    final controller = _controller;
    if (controller != null) {
      if (!_loaded && !controller.processing) {
        // 未经联动接管的加载（如用户在本机打开了同一视频）
        _loaded = true;
        _transport.send({'t': LinkMessageType.loaded, 'round': _round});
        if (_pendingRound != null) {
          _prepare();
        }
      }
      final player = controller.videoPlayerController!;
      if (!_shouldPlay) {
        // 跟随端只按主控的指令播放
        if (player.state.playing && _startTimer == null) {
          controller.pause();
        }
      } else if (player.state.playing) {
        drift = _follow(player, now);
      }
    }
    if (now - _lastReport >= _reportUs) {
      _lastReport = now;
      final rtt = _clock.rttUs;
      rttMs.value = rtt == null ? null : rtt / 1000;
      driftMs.value = drift;
      _transport.send({
        't': LinkMessageType.report,
        'drift': drift,
        'rtt': rttMs.value,
      });
    }
  }
}
