import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/services/linked_playback/calibration_signal.dart';
import 'package:PiliPlus/services/linked_playback/clock.dart';
import 'package:PiliPlus/services/linked_playback/diagnostics.dart';
import 'package:PiliPlus/services/linked_playback/player_access.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;

/// 一轮的计时结果：本轮扫频音前后推算的测试音文件起点实际发声的时刻（本机
/// 时钟，微秒），读数不足或不稳定时为空；及所用读数的极差（去掉两端各 10%）
/// 与个数
typedef CalibrationOrigin = ({
  int round,
  int? origin,
  int spread,
  int samples,
});

/// 本端的校准测试音：临时的纯音频播放器（无页面、无窗口），音频输出与输出设备
/// 取自本端当前的播放器（同一输出端点），在约定时刻开始播放，播完即释放。
/// 播放全程按 audio-pts 推算文件起点实际发声的时刻，每轮取本轮扫频音前后的
/// 读数各得一个起点，本轮读数结束后回调
class CalibrationTone {
  CalibrationTone({
    required this.plan,
    required this.slot,
    required this.reference,
    required this.startAt,
    required this.onRound,
    required this.onError,
  });

  final CalibrationPlan plan;
  final int slot;

  /// 本端当前的播放器，没有时按默认音频输出
  final Player? reference;

  /// 开始播放的时刻（本机时钟）
  final int startAt;

  /// 每轮的读数结束后调用
  final void Function(CalibrationOrigin origin) onRound;

  /// 未能播放时以原因调用，只调用一次，此后不再有回调
  final void Function(String error) onError;

  static const _sampleInterval = Duration(milliseconds: 20);

  /// 音频输出启动后此位置之后的读数才稳定
  static const _minPositionUs = 150000;
  static const _maxSampleCostUs = 4000;

  /// 每轮取本设备本轮中高频扫频音之前、最后一段低频扫频音之后这些时长内的
  /// 读数（按文件位置），约 1.2s、60 个读数
  static const _windowBeforeUs = 300000;
  static const _windowAfterUs = 100000;

  /// 一轮至少需要的读数
  static const _minSamples = 15;

  /// 一轮读数去掉两端各 10% 后的极差超过此值时不采用该轮。Windows 上读数
  /// 相差在 1ms 内；安卓的输出时间戳间隔更新、其间插值，平稳时在数毫秒内，偶发
  /// 的跳动由去掉两端排除；超出多半是输出时间戳仍在调整（起播初期、欠载后重新
  /// 同步），中位数也随之偏移
  static const _maxSpreadUs = 8000;

  /// 开始播放后此时长内没有可用读数视为未能播放
  static const _sampleTimeoutUs = 2000000;

  /// 复制自本端播放器的音频输出设置
  static const _copied = ['audio-device', 'audio-exclusive', 'audio-buffer'];

  Player? _player;
  String? _path;
  Timer? _sampler;
  Timer? _end;
  bool _stopped = false;
  bool _failed = false;

  /// 启动中、尚未创建播放器（构造后即调用 [start]）：此时停止由启动随后释放
  bool _starting = true;
  final Completer<void> _released = Completer<void>();
  int? _playedAt;

  /// 正在收集读数的轮次及其读数（起点时刻）
  int _round = 0;
  final List<int> _origins = [];
  bool _sampled = false;

  Future<void> start() async {
    try {
      final path = _path = p.join(
        tmpDirPath,
        'linked_calibration_${plan.id}_$slot.wav',
      );
      await File(path).writeAsBytes(CalibrationSignal.wav(plan, slot));
      if (_stopped) return _release();
      // 播放器默认不解码视频（vid=no），也不创建窗口
      final options = <String, String>{};
      final reference = this.reference;
      if (reference != null && !reference.disposed) {
        final ao = reference.getProperty('current-ao');
        options['ao'] = ao.isNotEmpty ? ao : reference.getProperty('ao');
        for (final name in _copied) {
          final value = reference.getProperty(name);
          if (value.isNotEmpty) options[name] = value;
        }
        final volume = reference.getProperty('volume');
        if (volume.isNotEmpty) options['volume'] = volume;
      } else if (Platform.isAndroid) {
        options['ao'] = Pref.audioOutput;
      } else if (PlatformUtils.isDesktop) {
        // 没有打开的播放器：本机音量为保存的桌面播放器音量
        options['volume'] = (Pref.desktopVolume * 100).toStringAsFixed(1);
      }
      // 校准临时提高音量：桌面端的本机音量即播放器音量，由测试音播放器直接按
      // 目标音量播放；安卓的系统媒体音量另行提高，播放器音量通常已是 100
      if (plan.volume case final target?) {
        final current = double.tryParse(options['volume'] ?? '') ?? 100;
        if (current < target * 100) {
          options['volume'] = (target * 100).toStringAsFixed(1);
        }
      }
      final Player player;
      try {
        player = await Player.create(
          configuration: PlayerConfiguration(
            logLevel: linkedDiagnostics.logLevel(.error),
            options: options,
          ),
        );
      } finally {
        _starting = false;
      }
      _player = player;
      linkedDiagnostics.attach(player, .error);
      if (_stopped) return _release();
      await player.open(Media(path), play: false);
      final delay = startAt - LinkClock.nowUs;
      if (delay > 0) await Future.delayed(Duration(microseconds: delay));
      if (_stopped) return;
      linkedDiagnostics.log(
        'calib tone slot=$slot late=${-delay} ao=${options['ao']} '
        'device=${options['audio-device']} volume=${options['volume']}',
      );
      _playedAt = LinkClock.nowUs;
      await player.play();
      if (_stopped) return;
      _sampler = Timer.periodic(_sampleInterval, (_) => _sample());
      _end = Timer(
        Duration(microseconds: plan.durationUs + _sampleTimeoutUs),
        stop,
      );
    } catch (e) {
      _fail('测试音未能播放：$e');
      // 创建播放器之前失败时由此释放
      _release();
    }
  }

  /// 第 [round] 轮取读数的文件位置范围
  int _windowStart(int round) => plan.chirpAtUs(slot, round) - _windowBeforeUs;

  int _windowEnd(int round) =>
      plan.chirpAtUs(slot, round, band: ChirpBand.lowMid) +
      ChirpBand.lowMid.durationUs +
      _windowAfterUs;

  void _sample() {
    final player = _player;
    if (_stopped || player == null) return;
    final sample = LinkedPlayer.sample(player);
    if (sample != null) {
      while (_round < CalibrationPlan.rounds &&
          sample.pos >= _windowEnd(_round)) {
        _finishRound();
      }
      if (sample.audio &&
          sample.cost <= _maxSampleCostUs &&
          sample.pos >= _minPositionUs &&
          sample.pos < plan.durationUs) {
        if (!_sampled) {
          _sampled = true;
          linkedDiagnostics.audioParams(player, 'calib tone slot=$slot');
        }
        if (_round < CalibrationPlan.rounds &&
            sample.pos >= _windowStart(_round)) {
          _origins.add(sample.at - sample.pos);
        }
      }
    }
    if (!_sampled && LinkClock.nowUs - _playedAt! > _sampleTimeoutUs) {
      _fail('测试音未能播放');
      return;
    }
    if (player.state.completed ||
        (sample != null && sample.pos >= plan.durationUs)) {
      stop();
    }
  }

  /// 结束当前轮的读数：取中位数，读数不足或极差过大时不采用
  void _finishRound() {
    final sorted = [..._origins]..sort();
    _origins.clear();
    final round = _round++;
    final trim = sorted.length ~/ 10;
    final spread = sorted.isEmpty
        ? 0
        : sorted[sorted.length - 1 - trim] - sorted[trim];
    final usable = sorted.length >= _minSamples && spread <= _maxSpreadUs;
    onRound((
      round: round,
      origin: usable ? sorted[sorted.length ~/ 2] : null,
      spread: spread,
      samples: sorted.length,
    ));
  }

  void _fail(String error) {
    if (_failed || _stopped) return;
    _failed = true;
    onError(error);
    stop();
  }

  /// 停止并释放；完成于播放器释放之后
  Future<void> stop() {
    if (!_stopped) {
      _stopped = true;
      _sampler?.cancel();
      _end?.cancel();
      if (!_starting) _release();
    }
    return _released.future;
  }

  Future<void>? _releasing;

  Future<void> _release() => _releasing ??= _dispose();

  Future<void> _dispose() async {
    final player = _player;
    _player = null;
    try {
      await player?.dispose();
    } catch (_) {}
    if (_path case final path?) {
      File(path).delete().catchError((_) => File(path));
    }
    _released.complete();
  }
}
