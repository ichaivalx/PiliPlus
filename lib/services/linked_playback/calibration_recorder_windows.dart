import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:PiliPlus/services/linked_playback/calibration_recorder.dart';
import 'package:PiliPlus/services/linked_playback/calibration_signal.dart';
import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart' as win32;

/// Windows：WinMM 以共享方式从默认录音设备录音，经系统音频引擎，不独占也不
/// 打开任何播放输出。缓冲区轮流交给系统，录满的定时取出后再交回
class WindowsCalibrationRecorder extends CalibrationRecorder {
  static const _waveMapper = 0xFFFFFFFF;
  static const _done = 0x1;
  static const _buffers = 20;

  /// 每个缓冲区 100ms，共 2s，取出间隔远小于此
  static const _bufferBytes = CalibrationPlan.sampleRate ~/ 10 * 2;
  static const _pollInterval = Duration(milliseconds: 40);

  win32.HWAVEIN? _handle;

  /// 全部缓冲区，及按交给系统的顺序排队、等待录满的缓冲区
  final List<Pointer<win32.WAVEHDR>> _headers = [];
  final List<Pointer<win32.WAVEHDR>> _queue = [];
  final BytesBuilder _data = BytesBuilder(copy: false);
  Timer? _poll;

  static int get _headerSize => sizeOf<win32.WAVEHDR>();

  static String _message(int code) => switch (code) {
    win32.MMSYSERR_BADDEVICEID || win32.MMSYSERR_NODRIVER => '未找到可用的麦克风',
    win32.MMSYSERR_ALLOCATED => '麦克风正被其他程序独占',
    _ => '无法打开麦克风（错误 $code）',
  };

  @override
  Future<String> start() async {
    await stop();
    final format = calloc<win32.WAVEFORMATEX>();
    final handle = calloc<Pointer>();
    try {
      format.ref
        ..wFormatTag = win32.WAVE_FORMAT_PCM
        ..nChannels = 1
        ..nSamplesPerSec = CalibrationPlan.sampleRate
        ..nAvgBytesPerSec = CalibrationPlan.sampleRate * 2
        ..nBlockAlign = 2
        ..wBitsPerSample = 16
        ..cbSize = 0;
      final opened = win32.waveInOpen(
        handle,
        _waveMapper,
        format,
        null,
        null,
        win32.CALLBACK_NULL,
      );
      if (opened != win32.MMSYSERR_NOERROR) {
        throw CalibrationRecorderError(_message(opened));
      }
      final hwi = _handle = win32.HWAVEIN(handle.value);
      for (var i = 0; i < _buffers; i++) {
        final header = calloc<win32.WAVEHDR>();
        header.ref
          ..lpData = win32.PSTR(calloc<Uint8>(_bufferBytes).cast<Utf8>())
          ..dwBufferLength = _bufferBytes;
        _headers.add(header);
        win32.waveInPrepareHeader(hwi, header, _headerSize);
        win32.waveInAddBuffer(hwi, header, _headerSize);
        _queue.add(header);
      }
      final started = win32.waveInStart(hwi);
      if (started != win32.MMSYSERR_NOERROR) {
        await stop();
        throw CalibrationRecorderError(_message(started));
      }
      _poll = Timer.periodic(_pollInterval, (_) => _drain(requeue: true));
      return 'winmm';
    } finally {
      calloc
        ..free(format)
        ..free(handle);
    }
  }

  /// 按顺序取出已录满的缓冲区；[requeue] 时再交给系统继续录
  void _drain({required bool requeue}) {
    final hwi = _handle;
    if (hwi == null) return;
    while (_queue.isNotEmpty && _queue.first.ref.dwFlags & _done != 0) {
      final header = _queue.removeAt(0);
      final recorded = header.ref.dwBytesRecorded;
      if (recorded > 0) {
        _data.add(
          Uint8List.fromList(
            header.ref.lpData.cast<Uint8>().asTypedList(recorded),
          ),
        );
      }
      if (requeue) {
        header.ref
          ..dwFlags = header.ref.dwFlags & ~_done
          ..dwBytesRecorded = 0;
        win32.waveInAddBuffer(hwi, header, _headerSize);
        _queue.add(header);
      }
    }
  }

  @override
  Future<Int16List> read() async {
    _drain(requeue: true);
    return CalibrationRecorder.samplesOf(_data.takeBytes());
  }

  @override
  Future<void> stop() async {
    _poll?.cancel();
    _poll = null;
    final hwi = _handle;
    if (hwi != null) {
      // 交回所有缓冲区（标记为已录满）后释放
      win32.waveInReset(hwi);
      _drain(requeue: false);
      for (final header in _headers) {
        win32.waveInUnprepareHeader(hwi, header, _headerSize);
        calloc
          ..free(header.ref.lpData)
          ..free(header);
      }
      win32.waveInClose(hwi);
    }
    _handle = null;
    _headers.clear();
    _queue.clear();
    _data.clear();
  }
}
