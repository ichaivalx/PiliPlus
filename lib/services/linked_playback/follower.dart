import 'dart:async';
import 'dart:math' show max;

import 'package:PiliPlus/grpc/bilibili/app/listener/v1.pbenum.dart'
    show PlaylistSource;
import 'package:PiliPlus/services/linked_playback/background_frames.dart';
import 'package:PiliPlus/services/linked_playback/clock.dart';
import 'package:PiliPlus/services/linked_playback/models.dart';
import 'package:PiliPlus/services/linked_playback/player_access.dart';
import 'package:PiliPlus/services/linked_playback/protocol.dart';
import 'package:PiliPlus/services/linked_playback/target.dart';
import 'package:PiliPlus/services/linked_playback/transport.dart';
import 'package:PiliPlus/services/linked_playback/volume.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';

/// 跟随端：按主控打开内容、定位、起播，并持续追齐主控的播放进度
class FollowerSession {
  FollowerSession({
    required this.deviceId,
    required this.deviceName,
    required this.syncOn,
    required this.onSyncChanged,
    required this.onOffsetChanged,
    required this.startBiasUs,
    required this.onStartBias,
    required this.seekCostUs,
    required this.onSeekCost,
    required String? lastLeader,
    required void Function(String) onLeader,
    required this.leader,
    required this.driftMs,
    required this.rttMs,
    required Rx<LinkedVolume> volume,
    required RxnDouble leaderVolume,
    required Future<double?> Function(double) setSystemVolume,
    required void Function(LinkedVolume) onVolumeSaved,
  }) {
    _volume = FollowerVolume(
      state: volume,
      leaderVolume: leaderVolume,
      setSystem: setSystemVolume,
      onSaved: onVolumeSaved,
      onChanged: _reportNow,
    );
    _transport = FollowerTransport(
      onConnected: _onConnected,
      onMessage: _onMessage,
      onDisconnected: _onDisconnected,
      onLeader: onLeader,
      lastLeader: lastLeader,
    );
  }

  static const _tickInterval = Duration(milliseconds: 250);
  static const _reportUs = 1000000;

  /// 起播后音频输出稳定前不做校正
  static const _settleUs = 1500000;

  /// 起播后在此时刻测量起播偏差，用于下次起播的补偿
  static const _learnUs = 1250000;
  static const _learnRate = 0.5;
  static const _maxStartBiasUs = 300000;
  static const _learnMaxDriftMs = 300.0;
  static const _learnMaxRttMs = 50.0;

  static const _interceptWindow = 8;
  static const _driftWindow = 4;

  /// 偏差超过 [_enterMs] 开始微调倍速，回到 [_exitMs] 以内停止
  static const _enterMs = 15.0;
  static const _exitMs = 4.0;

  /// 微调倍速按偏差在约此时长内追平，且不超过 [_maxAdjust]
  static const _tauSeconds = 2.0;
  static const _maxAdjust = 0.04;
  static const _adjustStep = 0.0025;

  /// 偏差超过此值时不用倍速追赶，本机直接跳转到主控的位置，主控不受影响
  static const _jumpMs = 100.0;

  /// 起播、跳转后经过此时间才判断是否需要跳转，避免同一偏差反复跳转
  static const _judgeUs = 2500000;

  /// 连续跳转仍未对齐的次数达到此值时，请主控共同暂停后重新共同起播
  static const _maxJumps = 2;

  /// 主控拖动进度后，收到新进度的样本数达到此值再跳转，避免按刚恢复播放时
  /// 不稳定的进度定位
  static const _seekSamples = 3;

  /// 跳转耗时（定位到缓冲就绪）按实测学习，起播时刻按此预留提前量
  static const _seekCostRate = 0.5;
  static const _minSeekCostUs = 100000;
  static const _maxSeekCostUs = 3000000;
  static const _seekLeadFactor = 1.5;
  static const _seekMarginUs = 150000;

  static const _resyncIntervalUs = 10000000;

  /// 打开内容期间应用在后台时驱动帧的上限，与主控等待加载的时间相同；
  /// 加载完成后再驱动一段时间以完成页面转场
  static const _openFrames = Duration(seconds: 20);
  static const _settleFrames = Duration(seconds: 1);
  static const _stallTicks = 4;

  /// 主控在播放而本机未跟上超过此时间时请求主控重新发送内容
  static const _lostUs = 6000000;
  static const _wantIntervalUs = 10000000;

  /// 请求偏移后在此时间内忽略主控回传的其他值
  static const _offsetEchoUs = 1000000;

  final String deviceId;
  final String deviceName;
  final bool Function() syncOn;
  final void Function(bool) onSyncChanged;
  final void Function(int) onOffsetChanged;
  int startBiasUs;
  final void Function(int) onStartBias;
  int seekCostUs;
  final void Function(int) onSeekCost;
  final RxnString leader;
  final RxnDouble driftMs;
  final RxnDouble rttMs;

  late final FollowerTransport _transport;
  late final FollowerVolume _volume;
  ClockSync get _clock => _transport.clock;
  Timer? _ticker;

  /// 连接前请求的同步开关与定时关闭到期，连接后发给主控
  bool? _pendingSync;
  bool _pendingStopAll = false;

  /// 主控本轮播放的内容
  LinkedContent? _content;
  int _round = 0;

  /// 最近打开的听视频页
  LinkedTarget? _audioTarget;

  /// 内容已在本机加载
  bool _loaded = false;
  int _loadToken = 0;
  String? _failure;

  /// 待定位的轮次与主控位置
  int? _pendingRound;
  int? _pendingPos;
  int? _readyRound;

  /// 主控的新指令使进行中的定位、定时起播作废
  int _generation = 0;
  bool _shouldPlay = false;
  Timer? _startTimer;
  int _offsetUs = 0;

  /// 本机最近请求的偏移；连续调节时主控依次回传的旧值不覆盖本机
  int? _requestedOffsetUs;
  int _requestedAt = 0;
  int? _pausePos;

  /// 主控的播放进度模型：位置 = 截距 + 倍速 × 主控时刻
  double _rate = 1.0;
  final List<int> _intercepts = [];
  final List<double> _drifts = [];
  bool _correcting = false;

  /// 延迟偏移变化后追到新目标前不受进入阈值限制
  bool _tracking = false;
  double _factor = 1.0;
  Player? _speedPlayer;
  double? _appliedSpeed;
  Player? _syncedPlayer;

  /// 当前定位所用的延迟偏移；起播时与当前偏移不同则定位已过期
  int? _positionedOffsetUs;

  /// 应跟随播放而被本机暂停（音频焦点、媒体控制等），本机恢复播放后重新对齐
  bool _localPaused = false;

  /// 主控拖动了进度：本机已暂停，等待主控新进度后跳转
  bool _awaitingSeek = false;

  /// 跳转中：本机已暂停并定位，等待到时起播
  bool _jumping = false;
  int _jumpToken = 0;

  /// 上次对齐成功后的跳转次数
  int _jumps = 0;

  int _settleUntil = 0;
  int _judgeAfter = 0;
  int? _learnAt;
  int _lastResync = -_resyncIntervalUs;
  int _lastReport = 0;
  int _stall = 0;

  /// 主控最近一次播放位置的时刻及内容
  int _leaderPosAt = -_lostUs;
  int? _leaderCid;
  int _lastProgress = 0;
  int _lastWant = -_wantIntervalUs;
  LinkedPeerState? _reportedState;

  bool get isConnected => _transport.isConnected;

  bool get isFollowing => isConnected && syncOn();

  LinkedTarget? _targetFor(LinkedKind? kind) => switch (kind) {
    LinkedKind.video => const VideoLinkedTarget(),
    LinkedKind.audio => _audioTarget,
    null => null,
  };

  LinkedTarget? get _target => _targetFor(_content?.kind);

  Player? get _loadedPlayer {
    final content = _content;
    return content == null ? null : _target?.playerFor(content.cid);
  }

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

  void wake() => _transport.wake();

  void refresh() => _transport.refresh();

  /// 用户在本机切换同步开关
  void requestSync(bool on) {
    if (isConnected) {
      _transport.send({'t': LinkMessageType.sync, 'on': on});
    } else {
      _pendingSync = on;
      _transport.wake();
    }
  }

  /// 用户在本机调节延迟偏移，由主控同步给所有跟随端
  void requestOffset(int offsetUs) {
    _setOffset(offsetUs);
    if (isConnected) {
      _requestedOffsetUs = offsetUs;
      _requestedAt = LinkClock.nowUs;
      _transport.send({'t': LinkMessageType.offset, 'us': offsetUs});
    }
  }

  /// 用户在本机调整音量设置
  void updateVolume(LinkedVolume value) => _volume.update(value);

  /// 本机系统媒体音量变化，[self] 为本机设置所致
  void onSystemVolume(double volume, {required bool self}) =>
      _volume.onSystemVolume(volume, self: self);

  /// 本机定时关闭到期，请主控一起停止
  void stopAll() {
    _halt();
    // 已就绪的轮次不再接受起播
    _readyRound = null;
    if (isConnected) {
      _transport.send(const {'t': LinkMessageType.stopAll});
    } else {
      _pendingStopAll = true;
    }
  }

  /// 同步开关变化后调用
  void applySync() {
    if (!syncOn()) {
      _clearContent();
    }
  }

  // 页面接入

  /// 跟随时本机的加载都不自动播放；与主控的内容一致时加载后回报
  LinkedLoad? gateLoad(LinkedContent? content, LinkedTarget target) {
    if (target.kind == LinkedKind.audio) {
      _audioTarget = target;
    }
    final current = _content;
    if (!isFollowing || current == null) {
      return null;
    }
    if (!current.isSame(content)) {
      return LinkedLoad(position: Duration.zero, onLoaded: () {});
    }
    final token = ++_loadToken;
    _halt();
    _loaded = false;
    _failure = null;
    final pendingPos = _pendingPos;
    return LinkedLoad(
      position: Duration(
        microseconds: pendingPos == null ? 0 : max(0, pendingPos - _offsetUs),
      ),
      onLoaded: () {
        if (token != _loadToken || _loadedPlayer == null) return;
        _onLoaded();
      },
    );
  }

  /// 会话启动时登记已打开的听视频页
  void adopt(LinkedTarget target) {
    if (target.kind == LinkedKind.audio) {
      _audioTarget = target;
    }
  }

  void releaseTarget(LinkedTarget target) {
    if (identical(target, _audioTarget)) {
      _audioTarget = null;
    }
  }

  void loadFailed(LinkedKind kind, int cid, String reason) {
    final content = _content;
    if (content != null && content.kind == kind && content.cid == cid) {
      _failure = reason;
    }
  }

  void _onLoaded() {
    LinkedFrames.finish(_settleFrames);
    _loaded = true;
    _failure = null;
    _transport.send({'t': LinkMessageType.loaded, 'round': _round});
    if (_pendingRound != null) {
      _prepare();
    }
  }

  // 连接

  void _onConnected() {
    _transport.send({
      't': LinkMessageType.hello,
      'id': deviceId,
      'name': deviceName,
      'sync': ?_pendingSync,
      if (_pendingStopAll) 'stopAll': true,
    });
    _pendingSync = null;
    _pendingStopAll = false;
    _lastProgress = LinkClock.nowUs;
    _volume.connect();
    leader.value = _transport.connection?.address;
    SmartDialog.showToast('联动播放：已连接主控 ${leader.value}');
  }

  void _onDisconnected() {
    _volume.disconnect();
    _clearContent();
    _release();
    leader.value = null;
    driftMs.value = null;
    rttMs.value = null;
    _reportedState = null;
    SmartDialog.showToast('联动播放：与主控的连接已断开，正在重新连接');
  }

  /// 停止跟随并忘记主控的内容
  void _clearContent() {
    _generation++;
    _loadToken++;
    _halt();
    _content = null;
    _loaded = false;
    _failure = null;
    _pendingRound = null;
    _pendingPos = null;
    _readyRound = null;
    _pausePos = null;
    _jumps = 0;
  }

  void _onMessage(LinkMessage message) {
    switch (message['t']) {
      case LinkMessageType.config:
        if (message['us'] case final int us) {
          final requested = _requestedOffsetUs;
          if (requested != null) {
            if (us == requested) {
              _requestedOffsetUs = null;
            } else if (LinkClock.nowUs - _requestedAt < _offsetEchoUs) {
              break;
            }
          }
          _setOffset(us);
          onOffsetChanged(us);
        }
      case LinkMessageType.sync:
        if (message['on'] case final bool on) {
          onSyncChanged(on);
        }
      case LinkMessageType.volume:
        if (message['v'] case final num volume) {
          _volume.onLeaderVolume(volume.toDouble());
        }
      case LinkMessageType.volumeSet:
        if (LinkedVolume.fromJson(message) case final volume?) {
          _volume.update(volume);
        }
      case LinkMessageType.open:
        final round = message['round'];
        final content = LinkedContent.fromJson(message['content']);
        if (round is! int || content == null || !syncOn()) return;
        _clearContent();
        _round = round;
        _content = content;
        _lastProgress = LinkClock.nowUs;
        if (_loadedPlayer != null && !(_target?.isLoading ?? false)) {
          _onLoaded();
        } else {
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
        _pausePos = pos;
        _lastProgress = LinkClock.nowUs;
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
          _lastProgress = LinkClock.nowUs;
          _scheduleStart(at, rate.toDouble());
        }
      case LinkMessageType.pause:
        _startTimer?.cancel();
        _startTimer = null;
        _shouldPlay = false;
        _resetCorrection();
        final player = _loadedPlayer;
        if (player == null) return;
        if (player.state.playing) {
          _target!.pause();
        }
        // 定位中时以定位为准
        if (message['pos'] case final int pos when _pendingRound == null) {
          _pausePos = pos;
          _target!.seek(Duration(microseconds: max(0, pos - _offsetUs)));
        }
      case LinkMessageType.position:
        _onLeaderPosition(message);
      case LinkMessageType.seek:
        _onLeaderSeek();
      case LinkMessageType.stop:
        _leaderCid = null;
        _leaderPosAt = -_lostUs;
        _clearContent();
    }
  }

  void _setOffset(int offsetUs) {
    if (offsetUs == _offsetUs) return;
    _offsetUs = offsetUs;
    // 起播后的测量包含旧偏移，不再用于补偿
    _learnAt = null;
    if (_shouldPlay) {
      _drifts.clear();
      _tracking = true;
      return;
    }
    // 暂停时直接定位到新的目标位置
    final pausePos = _pausePos;
    final player = _loadedPlayer;
    if (pausePos != null &&
        player != null &&
        _pendingRound == null &&
        !player.state.playing) {
      _positionedOffsetUs = null;
      _target!.seek(Duration(microseconds: max(0, pausePos - _offsetUs)));
    }
  }

  // 内容

  /// 当前页面可直接切换时在页内切换，否则打开新页面，替换最上层的播放页
  void _openContent(LinkedContent content) {
    // 熄屏、后台时页面需要帧才能挂载
    LinkedFrames.keep(_openFrames);
    final route = Get.currentRoute.split('?').first;
    final target = _targetFor(content.kind);
    final pageRoute = switch (content.kind) {
      LinkedKind.video => '/videoV',
      LinkedKind.audio => '/audio',
    };
    if (route == pageRoute && target != null && target.open(content)) {
      return;
    }
    final replace = route == '/videoV' || route == '/audio';
    switch (content.kind) {
      case LinkedKind.video:
        PageUtils.toVideoPage(
          aid: content.aid,
          bvid: content.bvid,
          cid: content.cid,
          cover: content.cover,
          title: content.title,
          off: replace,
          extraArguments: const {LinkedArgs.open: true},
        );
      case LinkedKind.audio:
        final arguments = {
          'oid': content.aid,
          'subId': [content.cid],
          'itemType': 1,
          'from': PlaylistSource.UP_ARCHIVE,
          LinkedArgs.open: true,
        };
        if (replace) {
          Get.offNamed('/audio', arguments: arguments);
        } else {
          Get.toNamed('/audio', arguments: arguments);
        }
    }
  }

  // 定位与起播

  Future<void> _prepare() async {
    final round = _pendingRound;
    final pos = _pendingPos;
    final target = _target;
    final player = _loadedPlayer;
    if (round == null || pos == null || target == null || player == null) {
      return;
    }
    final generation = _generation;
    bool isCurrent() => generation == _generation && isConnected;
    _link(player);
    if (player.state.playing) {
      await target.pause();
    }
    // 文件打开前无法定位
    if (await LinkedPlayer.waitLoaded(player, isCurrent) == null) return;
    // 定位期间延迟偏移变化时按新偏移重新定位
    int offset;
    do {
      offset = _offsetUs;
      final destination = max(0, pos - offset);
      await target.seek(Duration(microseconds: destination));
      if (!await LinkedPlayer.waitReady(player, destination, isCurrent)) {
        return;
      }
    } while (offset != _offsetUs);
    _positionedOffsetUs = offset;
    while (!_clock.isReady) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (!isCurrent()) return;
    }
    _pendingRound = null;
    _readyRound = round;
    _transport.send({'t': LinkMessageType.ready, 'round': round});
  }

  void _scheduleStart(int leaderAt, double rate) {
    final target = _target;
    if (target == null || _loadedPlayer == null) return;
    _setRate(target, rate);
    _resetCorrection();
    final generation = _generation;
    _startTimer?.cancel();
    _startTimer = LinkedPlayer.scheduleAt(
      _clock.toLocal(leaderAt) + startBiasUs,
      () {
        _startTimer = null;
        if (generation != _generation) return;
        final target = _target;
        if (target == null || _loadedPlayer == null) return;
        _shouldPlay = true;
        _jumps = 0;
        _onStarted();
        target.play();
      },
    );
  }

  void _onStarted() {
    final now = LinkClock.nowUs;
    _settleUntil = now + _settleUs;
    _judgeAfter = now + _judgeUs;
    _localPaused = false;
    _stall = 0;
    // 定位后延迟偏移又有变化：不用于起播补偿的学习，并立即追到新目标
    if (_positionedOffsetUs == _offsetUs) {
      _learnAt = now + _learnUs;
    } else {
      _learnAt = null;
      _tracking = true;
    }
  }

  /// 主控在播放而本机未参与起播（重新连接、加载较慢、错过本轮）
  bool _canJoin(int now) =>
      _loaded &&
      _pendingRound == null &&
      _startTimer == null &&
      _intercepts.isNotEmpty &&
      _clock.isReady &&
      _leaderCid == _content?.cid &&
      now - _leaderPosAt < _reportUs;

  /// 跳转对齐；多次跳转仍未对齐时请主控共同暂停后重新共同起播
  void _realign(LinkedTarget target, Player player, int now) {
    if (_jumps >= _maxJumps) {
      if (_requestResync(now)) {
        _jumps = 0;
      }
      return;
    }
    _jumps++;
    _jump(target, player);
  }

  /// 本机暂停并定位到主控在预留时间后的位置，到时起播；主控不受影响
  void _jump(LinkedTarget target, Player player) {
    final token = ++_jumpToken;
    _jumping = true;
    _shouldPlay = true;
    _correcting = false;
    _tracking = false;
    _factor = 1.0;
    _drifts.clear();
    _learnAt = null;
    _applySpeed(player);
    _runJump(target, player, token);
  }

  Future<void> _runJump(LinkedTarget target, Player player, int token) async {
    bool isCurrent() => token == _jumpToken && _shouldPlay && isConnected;
    if (player.state.playing) {
      await target.pause();
    }
    // 定位慢于预留时间时按更新后的耗时再试一次
    for (var attempt = 0; attempt < 2; attempt++) {
      if (!isCurrent()) return;
      final begin = LinkClock.nowUs;
      final at = begin + (seekCostUs * _seekLeadFactor).round() + _seekMarginUs;
      final leaderPos = _leaderPosition(at);
      if (leaderPos == null) break;
      final offset = _offsetUs;
      final destination = max(0, leaderPos - offset);
      await target.seek(Duration(microseconds: destination));
      if (!await LinkedPlayer.waitReady(player, destination, isCurrent)) return;
      _learnSeekCost(LinkClock.nowUs - begin);
      // 定位期间延迟偏移变化时重新定位
      if (offset != _offsetUs) continue;
      _positionedOffsetUs = offset;
      final playAt = at + startBiasUs;
      if (LinkClock.nowUs < playAt) {
        _startTimer = LinkedPlayer.scheduleAt(playAt, () {
          _startTimer = null;
          if (!isCurrent()) return;
          _jumping = false;
          _onStarted();
          target.play();
        });
        return;
      }
    }
    if (isCurrent()) {
      // 未能对齐，稍后重新加入
      _jumping = false;
      _shouldPlay = false;
    }
  }

  void _learnSeekCost(int cost) {
    final value = (seekCostUs + (cost - seekCostUs) * _seekCostRate)
        .round()
        .clamp(_minSeekCostUs, _maxSeekCostUs)
        .toInt();
    if (value != seekCostUs) {
      seekCostUs = value;
      onSeekCost(value);
    }
  }

  /// 停止跟随播放，保留已加载的内容
  void _halt() {
    _startTimer?.cancel();
    _startTimer = null;
    _shouldPlay = false;
    _learnAt = null;
    _resetCorrection();
    final player = _loadedPlayer;
    if (player != null && player.state.playing) {
      _target!.pause();
    }
  }

  void _link(Player player) {
    if (identical(player, _syncedPlayer) || _content?.kind != LinkedKind.video) {
      return;
    }
    _syncedPlayer = player;
    LinkedPlayer.setVideoSync(player, linked: true);
  }

  /// 恢复播放器的同步方式与倍速
  void _release() {
    final synced = _syncedPlayer;
    if (synced != null && !synced.disposed) {
      LinkedPlayer.setVideoSync(synced, linked: false);
    }
    final speed = _speedPlayer;
    if (speed != null && !speed.disposed) {
      LinkedPlayer.setSpeed(speed, speed.state.rate);
    }
    _syncedPlayer = null;
    _speedPlayer = null;
    _appliedSpeed = null;
  }

  // 追齐

  void _setRate(LinkedTarget target, double rate) {
    if (rate != _rate) {
      _rate = rate;
      _intercepts.clear();
      _drifts.clear();
    }
    if (target.rate != rate) {
      target.setRate(rate).whenComplete(() {
        if (_loadedPlayer case final player?) {
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
    _leaderPosAt = LinkClock.nowUs;
    _leaderCid = message['cid'] as int?;
    final target = _target;
    if (target != null && rate.toDouble() != _rate) {
      _setRate(target, rate.toDouble());
    }
    _intercepts.add(pos - (_rate * at).round());
    if (_intercepts.length > _interceptWindow) {
      _intercepts.removeAt(0);
    }
  }

  /// 主控播放中拖动进度：旧进度模型作废，本机立即停止旧位置的声音
  void _onLeaderSeek() {
    _intercepts.clear();
    _drifts.clear();
    if (!_shouldPlay) return;
    _jumpToken++;
    _jumping = false;
    _startTimer?.cancel();
    _startTimer = null;
    _localPaused = false;
    _correcting = false;
    _tracking = false;
    _factor = 1.0;
    _awaitingSeek = true;
    if (_loadedPlayer case final player?) {
      _applySpeed(player);
      if (player.state.playing) {
        _target!.pause();
      }
    }
  }

  void _resetCorrection() {
    _jumpToken++;
    _jumping = false;
    _awaitingSeek = false;
    _localPaused = false;
    _intercepts.clear();
    _drifts.clear();
    _correcting = false;
    _tracking = false;
    _factor = 1.0;
    if (_loadedPlayer case final player?) {
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

  /// 本机时刻 [localUs] 时主控的位置
  int? _leaderPosition(int localUs) {
    if (_intercepts.isEmpty || !_clock.isReady) return null;
    return (_median(_intercepts) + _rate * _clock.toRemote(localUs)).round();
  }

  /// 本机相对主控（已扣除延迟偏移）的偏差，正值表示本机超前（毫秒）
  double? _measure(Player player) {
    final sample = LinkedPlayer.sample(player);
    if (sample == null) return null;
    final leaderPos = _leaderPosition(sample.at);
    if (leaderPos == null) return null;
    _drifts.add((sample.pos - leaderPos + _offsetUs) / 1000);
    if (_drifts.length > _driftWindow) {
      _drifts.removeAt(0);
    }
    return _median(_drifts);
  }

  bool _requestResync(int now) {
    if (now - _lastResync < _resyncIntervalUs) return false;
    _lastResync = now;
    _transport.send({'t': LinkMessageType.resync, 'round': _round});
    _resetCorrection();
    return true;
  }

  /// 按起播后的实测偏差调整下次起播的补偿
  void _learnStartBias(double drift) {
    _learnAt = null;
    final rtt = _clock.rttUs;
    if (drift.abs() > _learnMaxDriftMs ||
        rtt == null ||
        rtt / 1000 > _learnMaxRttMs) {
      return;
    }
    final bias = (startBiasUs + drift * 1000 * _learnRate)
        .round()
        .clamp(-_maxStartBiasUs, _maxStartBiasUs)
        .toInt();
    if (bias != startBiasUs) {
      startBiasUs = bias;
      onStartBias(bias);
    }
  }

  double? _follow(LinkedTarget target, Player player, int now) {
    if (player.state.buffering) {
      if (++_stall >= _stallTicks) {
        _stall = 0;
        _requestResync(now);
      }
      return null;
    }
    _stall = 0;
    final drift = _measure(player);
    if (drift == null) return null;
    final learnAt = _learnAt;
    if (learnAt != null && now >= learnAt && _drifts.length >= 3) {
      _learnStartBias(drift);
    }
    if (now < _settleUntil) return drift;
    final magnitude = drift.abs();
    if (magnitude > _jumpMs) {
      // 大偏差不用倍速追赶
      _correcting = false;
      _tracking = false;
      _factor = 1.0;
      _applySpeed(player);
      if (now >= _judgeAfter && _drifts.length >= _driftWindow) {
        _realign(target, player, now);
      }
      return drift;
    }
    if (now >= _judgeAfter) {
      _jumps = 0;
    }
    if (_tracking) {
      _correcting = magnitude >= _exitMs;
      _tracking = _correcting;
    } else if (_correcting) {
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

  LinkedPeerState _state(Player? player) {
    final content = _content;
    if (!syncOn() || content == null) return LinkedPeerState.idle;
    if (_failure != null || _target?.failureFor(content.cid) != null) {
      return LinkedPeerState.failed;
    }
    if (player == null ||
        !_loaded ||
        _pendingRound != null ||
        _startTimer != null ||
        _jumping ||
        _awaitingSeek) {
      return LinkedPeerState.preparing;
    }
    if (_shouldPlay) {
      if (_localPaused) return LinkedPeerState.localPaused;
      return player.state.buffering
          ? LinkedPeerState.buffering
          : LinkedPeerState.playing;
    }
    return LinkedPeerState.paused;
  }

  void _tick(Timer _) {
    if (!isConnected) return;
    final now = LinkClock.nowUs;
    double? drift;
    final target = _target;
    final player = _loadedPlayer;
    if (syncOn() && target != null && player != null) {
      if (!_loaded && !target.isLoading) {
        // 未经联动接管的加载（如用户在本机打开了同一视频）
        _onLoaded();
      }
      if (_jumping) {
        // 等待跳转后起播
      } else if (_awaitingSeek) {
        if (_intercepts.length >= _seekSamples && _clock.isReady) {
          _awaitingSeek = false;
          _jumps = 0;
          _realign(target, player, now);
        }
      } else if (_shouldPlay) {
        if (!player.state.playing) {
          // 起播后稳定期过后仍未播放：被本机暂停，不强行恢复
          if (!_localPaused && _startTimer == null && now >= _settleUntil) {
            _localPaused = true;
            _correcting = false;
            _tracking = false;
            _factor = 1.0;
            _drifts.clear();
            _applySpeed(player);
          }
        } else if (_localPaused) {
          // 本机恢复播放（打断结束、用户播放）后跳转重新对齐
          _localPaused = false;
          _jumps = 0;
          _realign(target, player, now);
        } else {
          drift = _follow(target, player, now);
        }
      } else if (_canJoin(now)) {
        _realign(target, player, now);
      } else if (player.state.playing && _startTimer == null) {
        // 跟随端只按主控的指令播放
        target.pause();
      }
    }
    _watch(now);
    // 状态变化时立即回报
    final state = _state(player);
    if (state != _reportedState || now - _lastReport >= _reportUs) {
      _lastReport = now;
      _reportedState = state;
      _report(state, drift);
    }
  }

  /// 主控在播放而本机长时间没有跟上时，请主控重新发送内容
  void _watch(int now) {
    if (!syncOn() || now - _leaderPosAt > _reportUs * 2) {
      _lastProgress = now;
      return;
    }
    if (_shouldPlay && _content?.cid == _leaderCid) {
      _lastProgress = now;
      return;
    }
    if (now - _lastProgress > _lostUs && now - _lastWant > _wantIntervalUs) {
      _lastWant = now;
      _transport.send({'t': LinkMessageType.want});
    }
  }

  void _reportNow() {
    if (!isConnected) return;
    final state = _state(_loadedPlayer);
    _lastReport = LinkClock.nowUs;
    _reportedState = state;
    _report(state, driftMs.value);
  }

  void _report(LinkedPeerState state, double? drift) {
    final rtt = _clock.rttUs;
    rttMs.value = rtt == null ? null : rtt / 1000;
    driftMs.value = drift;
    final content = _content;
    _transport.send({
      't': LinkMessageType.report,
      'state': state.name,
      'reason': state == LinkedPeerState.failed
          ? _failure ??
                (content == null ? null : _target?.failureFor(content.cid))
          : null,
      'drift': drift,
      'rtt': rttMs.value,
      'volume': _volume.state.value.toJson(),
    });
  }
}
