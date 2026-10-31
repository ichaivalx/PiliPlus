import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:PiliPlus/services/linked_playback/calibration_recorder_windows.dart';
import 'package:PiliPlus/services/linked_playback/calibration_signal.dart';
import 'package:flutter/services.dart' show MethodChannel, PlatformException;

/// 校准录音：按 [CalibrationPlan.sampleRate] 录单声道 16 位，只使用录音设备，
/// 不涉及任何播放输出。录音与检测之外只有采集与平台相关
abstract class CalibrationRecorder {
  static bool get isSupported => Platform.isAndroid || Platform.isWindows;

  static CalibrationRecorder create() => Platform.isWindows
      ? WindowsCalibrationRecorder()
      : _AndroidCalibrationRecorder();

  /// 开始录音，返回实际使用的录音来源；失败时抛出 [CalibrationRecorderError]
  Future<String> start();

  /// 取出开始以来尚未取出的录音
  Future<Int16List> read();

  Future<void> stop();

  static Int16List samplesOf(Uint8List bytes) {
    final copy = Uint8List(bytes.length & ~1)
      ..setRange(0, bytes.length & ~1, bytes);
    return copy.buffer.asInt16List();
  }
}

class CalibrationRecorderError implements Exception {
  const CalibrationRecorderError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Android：AudioRecord，录音来源优先不做处理的 UNPROCESSED，其次语音识别、
/// 普通麦克风，并关闭回声消除、降噪与自动增益
class _AndroidCalibrationRecorder extends CalibrationRecorder {
  static const _channel = MethodChannel('com.example.piliplus/linked_calibration');

  @override
  Future<String> start() async {
    try {
      return await _channel.invokeMethod<String>('start', {
            'rate': CalibrationPlan.sampleRate,
          }) ??
          '';
    } on PlatformException catch (e) {
      throw CalibrationRecorderError(e.message ?? '无法打开麦克风');
    }
  }

  @override
  Future<Int16List> read() async {
    final bytes = await _channel.invokeMethod<Uint8List>('read');
    return bytes == null
        ? Int16List(0)
        : CalibrationRecorder.samplesOf(bytes);
  }

  @override
  Future<void> stop() => _channel.invokeMethod<void>('stop');
}
