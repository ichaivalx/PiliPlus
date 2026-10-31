import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/services/linked_playback/calibration_signal.dart';
import 'package:PiliPlus/services/linked_playback/clock.dart';
import 'package:PiliPlus/services/linked_playback/diagnostics.dart';
import 'package:PiliPlus/services/linked_playback/player_access.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;

/// 测试音文件起点实际发声的时刻（本机时钟，微秒），及所用读数的极差与个数
typedef CalibrationOrigin = ({int origin, int spread, int samples});

/// 本端的校准测试音：临时的纯音频播放器（无页面、无窗口），音频输出与输出设备
/// 取自本端当前的播放器（同一输出端点），在约定时刻开始播放，播完即释放。
/// 播放中按 audio-pts 推算文件起点实际发声的时刻，读数够数后回调一次
class CalibrationTone {
  CalibrationTone({
    required this.plan,
    required this.slot,
    required this.reference,
    required this.startAt,
    required this.onResult,
  });

  final CalibrationPlan plan;
  final int slot;

  /// 本端当前的播放器，没有时按默认音频输出
  final Player? reference;

  /// 开始播放的时刻（本机时钟）
  final int startAt;

  /// 推算出起点时刻，或未能播放时以原因调用，只调用一次
  final void Function(CalibrationOrigin? origin, String? error) onResult;

  static const _sampleInterval = Duration(milliseconds: 20);

  /// 音频输出启动后此位置之后的读数才稳定
  static const _minPositionUs = 150000;
  static const _samplesNeeded = 12;
  static const _maxSampleCostUs = 4000;

  /// 读数超过此时长仍不够数视为未能播放
  static const _sampleTimeoutUs = 2000000;

  /// 复制自本端播放器的音频输出设置
  static const _copied = ['audio-device', 'audio-exclusive', 'audio-buffer'];

  Player? _player;
  String? _path;
  Timer? _sampler;
  Timer? _end;
  bool _stopped = false;
  bool _reported = false;
  int? _playedAt;
  final List<int> _origins = [];

  Future<void> start() async {
    try {
      final path = _path = p.join(
        tmpDirPath,
        'linked_calibration_${plan.id}_$slot.wav',
      );
      await File(path).writeAsBytes(CalibrationSignal.wav(plan, slot));
      if (_stopped) return _cleanup();
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
      }
      final player = _player = await Player.create(
        configuration: PlayerConfiguration(
          logLevel: linkedDiagnostics.logLevel(.error),
          options: options,
        ),
      );
      linkedDiagnostics.attach(player, .error);
      if (_stopped) return _cleanup();
      await player.open(Media(path), play: false);
      final delay = startAt - LinkClock.nowUs;
      if (delay > 0) await Future.delayed(Duration(microseconds: delay));
      if (_stopped) return _cleanup();
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
      _report(null, '测试音未能播放：$e');
      stop();
    }
  }

  void _sample() {
    final player = _player;
    if (_stopped || player == null) return;
    final sample = LinkedPlayer.sample(player);
    final now = LinkClock.nowUs;
    if (sample != null &&
        sample.audio &&
        sample.cost <= _maxSampleCostUs &&
        sample.pos >= _minPositionUs &&
        sample.pos < plan.durationUs) {
      _origins.add(sample.at - sample.pos);
      if (_origins.length == _samplesNeeded) {
        final sorted = [..._origins]..sort();
        _report((
          origin: sorted[sorted.length ~/ 2],
          spread: sorted.last - sorted.first,
          samples: sorted.length,
        ), null);
      }
    } else if (!_reported && now - _playedAt! > _sampleTimeoutUs) {
      _report(null, '测试音未能播放');
    }
    if (player.state.completed ||
        (sample != null && sample.pos >= plan.durationUs)) {
      stop();
    }
  }

  void _report(CalibrationOrigin? origin, String? error) {
    if (_reported) return;
    _reported = true;
    onResult(origin, error);
  }

  /// 停止并释放；进行中的启动在下一步发现已停止后释放其创建的播放器
  void stop() {
    if (_stopped) return;
    _stopped = true;
    _sampler?.cancel();
    _end?.cancel();
    _cleanup();
  }

  void _cleanup() {
    _report(null, '已停止');
    _player?.dispose();
    _player = null;
    if (_path case final path?) {
      File(path).delete().catchError((_) => File(path));
    }
  }
}
