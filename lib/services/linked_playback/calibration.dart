import 'dart:async';
import 'dart:io' show Platform;
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:PiliPlus/services/linked_playback/calibration_recorder.dart';
import 'package:PiliPlus/services/linked_playback/calibration_signal.dart';
import 'package:PiliPlus/services/linked_playback/calibration_tone.dart';
import 'package:PiliPlus/services/linked_playback/clock.dart';
import 'package:PiliPlus/services/linked_playback/diagnostics.dart';
import 'package:PiliPlus/services/linked_playback/leader.dart';
import 'package:PiliPlus/services/linked_playback/linked_playback.dart'
    show LinkedPlayback;
import 'package:PiliPlus/services/linked_playback/offset_dial.dart';
import 'package:PiliPlus/services/linked_playback/protocol.dart';
import 'package:PiliPlus/utils/permission_handler.dart';
import 'package:collection/collection.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';

final linkedCalibration = LinkedCalibration._();

enum CalibrationStage { pausing, playing, computing, done, failed }

/// 参与校准的一台设备
class CalibrationDevice {
  CalibrationDevice({
    required this.id,
    required this.name,
    required this.slot,
    this.offsetUs,
  });

  /// 跟随端的设备标识，主控（基准）为空
  final String? id;
  final String name;
  final int slot;

  /// 校准前的延迟偏移
  final int? offsetUs;

  /// 测试音文件起点实际发声的时刻（主控时钟）或未能播放的原因
  int? origin;
  String? toneError;

  /// 各轮测得的相对主控的声学延迟差（微秒），正值为声音偏晚；主控记录检测到
  /// 自身测试音的轮次（均为 0）
  final List<double> rounds = [];

  /// 采用的延迟差与写入的偏移，未能校准时为原因
  int? lateUs;
  int? newOffsetUs;
  String? problem;

  bool get isReference => id == null;

  /// 校准进行中的状态
  String get status {
    if (isReference) return '基准';
    if (rounds.isNotEmpty) {
      return '已检测到 ${rounds.length}/${CalibrationPlan.rounds}';
    }
    return toneError == null ? '等待' : '未能播放测试音';
  }

  /// 校准完成后的结果
  String get result {
    if (isReference) return '基准';
    if (problem case final problem?) return problem;
    return '${formatLinkedOffset(lateUs!)} → 已补偿'
        '（原 ${formatLinkedOffset(offsetUs ?? 0)}）';
  }
}

/// 一轮检测的输入：录音、录音起点（主控时钟）与各设备本轮扫频音的发声时刻
typedef _RoundInput = ({
  Int16List samples,
  int recordStart,
  List<int?> emits,
});

typedef _Hit = ({int slot, double index, double snr});

/// 先在预计位置附近找主控自身的测试音，各跟随端再按与主控的发声时刻之差在
/// 其附近寻找，窗口足以容纳输出与录音的未知延迟
List<_Hit> _detectRound(_RoundInput input) {
  int samplesOf(num us) => (us * CalibrationPlan.sampleRate / 1e6).round();
  final emits = input.emits;
  final leaderEmit = emits[0];
  if (leaderEmit == null) return const [];
  final expected = samplesOf(leaderEmit - input.recordStart);
  final lead = detectChirp(
    input.samples,
    0,
    expected - samplesOf(250000),
    expected + samplesOf(600000),
  );
  if (lead == null) return const [];
  final hits = <_Hit>[(slot: 0, index: lead.index, snr: lead.snr)];
  if (lead.snr < CalibrationSignal.minSnr) return hits;
  for (var slot = 1; slot < emits.length; slot++) {
    final emit = emits[slot];
    if (emit == null) continue;
    final at = lead.index + samplesOf(emit - leaderEmit);
    final found = detectChirp(
      input.samples,
      slot,
      (at - samplesOf(300000)).floor(),
      (at + samplesOf(500000)).ceil(),
    );
    if (found != null) {
      hits.add((slot: slot, index: found.index, snr: found.snr));
    }
  }
  return hits;
}

/// 在后台检测一轮；只经顶层函数传入输入，不带上调用方的其他状态
Future<List<_Hit>> _detectInBackground(_RoundInput input) =>
    Isolate.run(() => _detectRound(input));

/// 主控的一键声学校准：一起暂停后各设备依次播放测试音（共 [CalibrationPlan.rounds]
/// 轮），主控录音并检测各测试音的到达时刻，按与主控的声学延迟差替换各跟随端
/// 的延迟偏移，结束后恢复播放
class LinkedCalibration {
  LinkedCalibration._();

  /// 发出安排到开始播放的时间：暂停播放、各端创建播放器并打开测试音
  static const _prepareUs = 1000000;

  /// 声音从发声到录入的最大延迟（含录音起点的误差），检测在此之后进行
  static const _maxLatencyUs = 500000;
  static const _tickInterval = Duration(milliseconds: 100);

  /// 与各轮中位数相差超过此值的结果不采用，采用的不足两轮时不校准该设备
  static const _consistencyUs = 3000;

  /// 录音的均方根（16 位采样）低于此值视为没有录到任何声音
  static const _silentRms = 2.0;

  final Rxn<CalibrationStage> stage = Rxn<CalibrationStage>();
  final RxInt round = 0.obs;
  final RxDouble progress = 0.0.obs;
  final RxList<CalibrationDevice> devices = <CalibrationDevice>[].obs;
  final RxnString message = RxnString();

  /// 失败原因需在系统设置中解决（权限被永久拒绝）
  final RxBool needsSettings = false.obs;

  bool get isRunning => switch (stage.value) {
    CalibrationStage.pausing ||
    CalibrationStage.playing ||
    CalibrationStage.computing => true,
    _ => false,
  };

  /// 每次开始、取消时递增，作废进行中的异步步骤
  int _generation = 0;
  LeaderSession? _leader;
  CalibrationRecorder? _recorder;
  CalibrationTone? _tone;
  CalibrationPlan? _plan;
  Timer? _ticker;
  bool _wasPlaying = false;
  bool _paused = false;
  int _beginAt = 0;
  int _recordStart = 0;
  final List<Int16List> _chunks = [];
  Future<void> _reading = Future.value();
  Future<void> _detecting = Future.value();
  int _scheduledRounds = 0;
  bool _finishing = false;

  static String get _microphoneHint => Platform.isWindows
      ? '\n请在 Windows 设置 → 隐私和安全性 → 麦克风中打开「麦克风访问权限」与'
            '「让桌面应用访问麦克风」，并确认默认录音设备可用'
      : '\n请确认系统未关闭麦克风访问（快捷设置中的麦克风开关），且麦克风未被'
            '其他应用占用';

  Future<void> start(LeaderSession leader) async {
    if (isRunning) return;
    final generation = ++_generation;
    _leader = leader;
    _plan = null;
    _chunks.clear();
    _reading = Future.value();
    _detecting = Future.value();
    _scheduledRounds = 0;
    _finishing = false;
    _paused = false;
    message.value = null;
    needsSettings.value = false;
    round.value = 0;
    progress.value = 0;
    devices.clear();
    stage.value = CalibrationStage.pausing;
    _beginAt = LinkClock.nowUs;
    if (Platform.isAndroid) {
      final status = await Permission.microphone.request();
      if (generation != _generation) return;
      if (!status.isGranted) {
        needsSettings.value = status.isPermanentlyDenied;
        return _fail('未获得麦克风权限：校准需要用主控的麦克风录下各设备的测试音');
      }
    }
    final peers = leader.calibrationPeers;
    if (leader.isClosed || peers.isEmpty) return _fail('没有可校准的跟随端');
    devices.assignAll([
      CalibrationDevice(id: null, name: '本机（主控）', slot: 0),
      for (final (index, peer) in peers.indexed)
        CalibrationDevice(
          id: peer.id,
          name: peer.name,
          slot: index + 1,
          offsetUs: peer.offsetUs,
        ),
    ]);
    _wasPlaying = leader.pauseForCalibration();
    _paused = true;
    leader.onCalibration = _onMessage;
    final recorder = _recorder = CalibrationRecorder.create();
    final String source;
    try {
      source = await recorder.start();
    } catch (e) {
      if (generation == _generation) {
        _fail(
          '${e is CalibrationRecorderError ? e.message : '无法打开麦克风：$e'}'
          '$_microphoneHint',
        );
      }
      return;
    }
    if (generation != _generation) {
      recorder.stop();
      return;
    }
    _recordStart = LinkClock.nowUs;
    final plan = _plan = CalibrationPlan(
      id: math.Random().nextInt(1 << 30),
      devices: devices.length,
      startAt: LinkClock.nowUs + _prepareUs,
    );
    linkedDiagnostics.log(
      'calib start id=${plan.id} devices=${plan.devices} start=${plan.startAt} '
      'record=$_recordStart source=$source '
      'peers=${[for (final device in devices.skip(1)) '${device.slot}:${device.name}:${device.offsetUs}'].join(',')}',
    );
    for (final device in devices.skip(1)) {
      leader.sendTo(device.id!, {
        't': LinkMessageType.calibrate,
        ...plan.toJson(),
        'slot': device.slot,
      });
    }
    final self = devices.first;
    _tone = CalibrationTone(
      plan: plan,
      slot: 0,
      reference: leader.calibrationReference,
      startAt: plan.startAt,
      onResult: (origin, error) {
        if (generation != _generation) return;
        self
          ..origin = origin?.origin
          ..toneError = error;
        linkedDiagnostics.log(
          'calib origin slot=0 origin=${origin?.origin} '
          'spread=${origin?.spread} n=${origin?.samples} error=$error',
        );
        devices.refresh();
      },
    )..start();
    _ticker = Timer.periodic(_tickInterval, (_) => _tick(generation));
  }

  void _onMessage(String id, LinkMessage message) {
    final plan = _plan;
    if (!isRunning || plan == null || message['id'] != plan.id) return;
    final device = devices.firstWhereOrNull((e) => e.id == id);
    if (device == null) return;
    final origin = message['origin'];
    final error = message['error'];
    device
      ..origin = origin is int ? origin : null
      ..toneError = origin is int
          ? null
          : (error is String ? error : '测试音未能播放');
    linkedDiagnostics.log(
      'calib origin slot=${device.slot} origin=$origin '
      'spread=${message['spread']} n=${message['samples']} error=$error',
    );
    devices.refresh();
  }

  /// 第 [index] 轮的检测时刻：本轮最后一台设备的测试音应已录入
  int _deadline(CalibrationPlan plan, int index) =>
      plan.startAt +
      plan.chirpAtUs(plan.devices - 1, index) +
      CalibrationSignal.chirpUs +
      _maxLatencyUs;

  void _tick(int generation) {
    if (generation != _generation) return;
    final leader = _leader!;
    final plan = _plan!;
    if (leader.isClosed) {
      _fail('联动已关闭');
      return;
    }
    if (leader.playIntended && !_finishing) {
      // 用户在校准期间恢复了播放
      cancel(resume: false);
      SmartDialog.showToast('已恢复播放，校准已取消');
      return;
    }
    _read();
    final now = LinkClock.nowUs;
    final end = _deadline(plan, CalibrationPlan.rounds - 1);
    progress.value =
        ((now - _beginAt) / (end - _beginAt)).clamp(0.0, 1.0) * 0.95;
    if (now >= plan.startAt && stage.value == CalibrationStage.pausing) {
      stage.value = CalibrationStage.playing;
    }
    if (now >= plan.startAt) {
      final elapsed = now - plan.startAt - CalibrationPlan.leadUs;
      round.value =
          (elapsed ~/ (plan.devices * CalibrationPlan.spacingUs) + 1)
              .clamp(1, CalibrationPlan.rounds)
              .toInt();
    }
    while (_scheduledRounds < CalibrationPlan.rounds &&
        now >= _deadline(plan, _scheduledRounds)) {
      _schedule(generation, plan, _scheduledRounds++);
    }
    if (_scheduledRounds == CalibrationPlan.rounds && !_finishing) {
      _finishing = true;
      stage.value = CalibrationStage.computing;
      _finish(generation);
    }
  }

  void _read() {
    final recorder = _recorder;
    if (recorder == null) return;
    _reading = _reading.then((_) async {
      final chunk = await recorder.read();
      if (chunk.isNotEmpty) _chunks.add(chunk);
    }).catchError((_) {});
  }

  Int16List _merged() {
    if (_chunks.length == 1) return _chunks.first;
    final merged = Int16List(_chunks.fold(0, (sum, e) => sum + e.length));
    var offset = 0;
    for (final chunk in _chunks) {
      merged.setRange(offset, offset += chunk.length, chunk);
    }
    _chunks
      ..clear()
      ..add(merged);
    return merged;
  }

  /// 第 [index] 轮的检测在后台进行，各轮依次
  void _schedule(int generation, CalibrationPlan plan, int index) {
    _detecting = _detecting
        .then((_) => _reading)
        .then((_) async {
          if (generation != _generation) return;
          final emits = [
            for (final device in devices)
              if (device.origin case final origin?)
                origin + plan.chirpAtUs(device.slot, index)
              else
                null,
          ];
          final input = (
            samples: _merged(),
            recordStart: _recordStart,
            emits: emits,
          );
          final hits = await _detectInBackground(input);
          if (generation != _generation) return;
          _apply(index, emits, hits);
        })
        .catchError((e) {
          linkedDiagnostics.log('calib detect round=$index error=$e');
        });
  }

  void _apply(int index, List<int?> emits, List<_Hit> hits) {
    const rate = CalibrationPlan.sampleRate;
    final lead = hits.firstWhereOrNull((e) => e.slot == 0);
    for (final hit in hits) {
      linkedDiagnostics.log(
        'calib hit round=$index slot=${hit.slot} '
        'index=${hit.index.toStringAsFixed(2)} '
        'at=${(_recordStart + hit.index / rate * 1e6).round()} '
        'emit=${emits[hit.slot]} snr=${hit.snr.toStringAsFixed(1)}',
      );
    }
    if (lead == null || lead.snr < CalibrationSignal.minSnr) {
      linkedDiagnostics.log('calib round=$index reference missed');
      return;
    }
    devices.first.rounds.add(0);
    for (final hit in hits) {
      if (hit.slot == 0 || hit.snr < CalibrationSignal.minSnr) continue;
      final late =
          (hit.index - lead.index) / rate * 1e6 -
          (emits[hit.slot]! - emits[0]!);
      devices[hit.slot].rounds.add(late);
      linkedDiagnostics.log(
        'calib round=$index slot=${hit.slot} late=${late.toStringAsFixed(0)}',
      );
    }
    devices.refresh();
  }

  Future<void> _finish(int generation) async {
    await _detecting;
    await _reading;
    if (generation != _generation) return;
    final recorder = _recorder;
    _recorder = null;
    await recorder?.stop();
    if (generation != _generation) return;
    final samples = _merged();
    var energy = 0.0;
    for (final value in samples) {
      energy += value * value;
    }
    final rms = samples.isEmpty ? 0.0 : math.sqrt(energy / samples.length);
    linkedDiagnostics.log(
      'calib recorded samples=${samples.length} rms=${rms.toStringAsFixed(1)}',
    );
    if (rms < _silentRms) {
      return _fail('麦克风没有录到任何声音$_microphoneHint');
    }
    if (devices.first.rounds.length < 2) {
      return _fail('未录到主控自己的测试音：请确认本机未静音、音量足够，且麦克风未被遮挡');
    }
    final leader = _leader!;
    for (final device in devices.skip(1)) {
      device.problem = _resolve(device);
      final late = device.lateUs;
      if (late == null) continue;
      const step = LinkedPlayback.offsetStepUs;
      final offset = (-late / step).round() * step;
      device.newOffsetUs = offset;
      if (!leader.isClosed) leader.setOffset(device.id!, offset);
    }
    linkedDiagnostics.log(
      'calib result ${[for (final device in devices.skip(1)) 'slot=${device.slot} rounds=${device.rounds.map((e) => e.round()).join('/')} late=${device.lateUs} offset=${device.offsetUs}->${device.newOffsetUs} problem=${device.problem}'].join('; ')}',
    );
    stage.value = CalibrationStage.done;
    progress.value = 1;
    devices.refresh();
    _end(resume: true);
  }

  /// 按各轮结果确定该设备的延迟差，不能确定时返回原因
  String? _resolve(CalibrationDevice device) {
    if (device.origin == null) {
      return device.toneError == null
          ? '未收到该设备的测试音信息（可能未更新到同一版本），保留原设置'
          : '未能播放测试音（${device.toneError}），保留原设置';
    }
    final values = [...device.rounds]..sort();
    if (values.length < 2) return '未录到声音（可能音量太小），保留原设置';
    final median = values[values.length ~/ 2];
    final agreed = [
      for (final value in values)
        if ((value - median).abs() <= _consistencyUs) value,
    ];
    if (agreed.length < 2) return '多轮结果不一致（可能受噪声或回声干扰），保留原设置';
    device.lateUs = agreed[agreed.length ~/ 2].round();
    return null;
  }

  void _fail(String reason) {
    linkedDiagnostics.log('calib failed $reason');
    message.value = reason;
    stage.value = CalibrationStage.failed;
    _end(resume: true);
  }

  /// 结束本次校准：停止测试音与录音，通知跟随端停止，按需恢复播放
  void _end({required bool resume}) {
    _generation++;
    _ticker?.cancel();
    _ticker = null;
    _tone?.stop();
    _tone = null;
    _recorder?.stop();
    _recorder = null;
    final leader = _leader;
    if (leader != null && !leader.isClosed) {
      if (_plan case final plan?) {
        leader.broadcast({'t': LinkMessageType.calibrateStop, 'id': plan.id});
      }
      if (leader.onCalibration == _onMessage) leader.onCalibration = null;
      if (resume && _paused && _wasPlaying) leader.resumeAfterCalibration();
    }
    _paused = false;
  }

  /// 取消进行中的校准：偏移未改动，按需恢复播放
  void cancel({bool resume = true}) {
    if (!isRunning) return;
    linkedDiagnostics.log('calib cancelled');
    _end(resume: resume);
    stage.value = null;
  }

  /// 关闭结果
  void close() {
    if (isRunning) return;
    stage.value = null;
  }

  /// 撤销本次校准写入的偏移
  void undo() {
    final leader = _leader;
    if (leader != null && !leader.isClosed) {
      for (final device in devices) {
        if (device.newOffsetUs != null && device.offsetUs != null) {
          leader.setOffset(device.id!, device.offsetUs!);
        }
      }
      SmartDialog.showToast('已恢复校准前的延迟偏移');
    }
    linkedDiagnostics.log('calib undone');
    stage.value = null;
  }
}
