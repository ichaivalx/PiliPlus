// ignore_for_file: implementation_imports

import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/services/linked_playback/clock.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:media_kit/ffi/src/allocation.dart';
import 'package:media_kit/ffi/src/utf8.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

final linkedDiagnostics = LinkedDiagnostics._();

/// 联动诊断记录（默认关闭）：开启后把联动期间的同步数据、对时样本与播放器音频
/// 输出信息写入滚动日志文件。先在内存中累积，定时追加写入；当前文件超过上限时
/// 改为备份文件（只保留一个），从新文件继续写
class LinkedDiagnostics {
  LinkedDiagnostics._();

  static const _enabledKey = 'linkedPlaybackDiagnostics';

  /// 单个文件的上限，加上一个备份共约两倍
  static const _maxBytes = 2 * 1024 * 1024;
  static const _flushInterval = Duration(seconds: 2);

  /// 播放器属性的复查间隔，有变化时记录
  static const _propertyIntervalUs = 5000000;

  /// 记录的 mpv 属性：音频输出、格式、倍速与音调校正等
  static const _properties = [
    'mpv-version',
    'current-ao',
    'audio-device',
    'audio-exclusive',
    'audio-buffer',
    'audio-params',
    'audio-out-params',
    'audio-pitch-correction',
    'audio-delay',
    'speed',
  ];

  final RxBool enabled = RxBool(
    GStorage.setting.get(_enabledKey, defaultValue: false) as bool,
  );

  /// 开启时为 true，记录前先判断，关闭时不产生任何开销
  bool get isOn => enabled.value;

  /// 新创建的播放器的 mpv 日志级别：开启时输出音频相关的详细日志，否则为平时
  /// 的 [normal]；创建后在打开媒体前交给 [attach]
  MPVLogLevel logLevel(MPVLogLevel normal) => isOn ? MPVLogLevel.v : normal;

  String get directory => p.join(appSupportDirPath, 'linked_playback_logs');
  String get filePath => p.join(directory, 'linked.log');
  String get _backupPath => p.join(directory, 'linked.1.log');

  final StringBuffer _buffer = StringBuffer();
  Timer? _flushTimer;
  Future<void> _writing = Future.value();
  int? _size;

  /// 退出应用时停止记录
  bool _closed = false;

  /// 以详细日志级别创建、仍在接收其音频日志的播放器及其平时的日志级别
  final Map<
    Player,
    ({MPVLogLevel normal, StreamSubscription<PlayerLog> logs})
  >
  _verbose = {};

  Player? _player;
  String? _lastProperties;
  int _propertiesAt = 0;

  void setEnabled(bool value) {
    if (value == enabled.value) return;
    if (!value) {
      log('diagnostics off');
      _player = null;
      _lastProperties = null;
      // 原生端仍会按详细级别产生日志，恢复为平时的级别
      for (final MapEntry(key: player, value: entry) in _verbose.entries) {
        entry.logs.cancel();
        _requestLogLevel(player, entry.normal);
      }
      _verbose.clear();
    }
    enabled.value = value;
    GStorage.setting.put(_enabledKey, value);
    if (value) {
      log('diagnostics on');
    } else {
      flush();
    }
  }

  /// 记录一行：本地时间、本机单调时钟（微秒）与内容
  void log(String text) {
    if (!isOn || _closed) return;
    _buffer
      ..write(DateTime.now().toIso8601String())
      ..write(' ')
      ..write(LinkClock.nowUs)
      ..write(' ')
      ..writeln(text);
    _flushTimer ??= Timer(_flushInterval, flush);
  }

  /// 以 [logLevel] 创建的播放器（[normal] 为平时的级别），在打开媒体前调用，
  /// 以免漏掉起播时音频输出初始化的日志：接收其音频相关日志（标注播放器），
  /// 关闭记录时恢复平时的级别
  void attach(Player player, MPVLogLevel normal) {
    if (player.configuration.logLevel == normal) return;
    if (!isOn || _closed) {
      // 创建期间已关闭
      _requestLogLevel(player, normal);
      return;
    }
    _verbose.removeWhere((key, entry) {
      if (!key.disposed) return false;
      entry.logs.cancel();
      return true;
    });
    final tag = player.hashCode;
    _verbose[player] = (
      normal: normal,
      logs: player.stream.log.listen((entry) {
        if (_isAudioLog(entry)) {
          log('mpv #$tag ${entry.prefix} ${entry.level} ${entry.text.trim()}');
        }
      }),
    );
  }

  static void _requestLogLevel(Player player, MPVLogLevel level) {
    if (player.disposed) return;
    final name = level.name.toNativeUtf8(allocator: calloc);
    NativePlayer.mpv.mpv_request_log_messages(player.ctx, name);
    calloc.free(name);
  }

  /// 本端正在使用的播放器（[role] 为主控或跟随），每次采样时调用：换了播放器时
  /// 记录其音频属性，之后定期复查属性的变化
  void observe(Player player, String role) {
    if (!isOn || _closed || player.disposed) return;
    final now = LinkClock.nowUs;
    if (!identical(player, _player)) {
      _player = player;
      _lastProperties = null;
      log('player $role #${player.hashCode}');
    } else if (now - _propertiesAt < _propertyIntervalUs) {
      return;
    }
    _propertiesAt = now;
    final buffer = StringBuffer();
    for (final name in _properties) {
      buffer.write(' $name=${player.getProperty(name)}');
    }
    final properties = buffer.toString();
    if (properties != _lastProperties) {
      _lastProperties = properties;
      log('props$properties');
    }
  }

  static bool _isAudioLog(PlayerLog entry) =>
      entry.prefix == 'ao' ||
      entry.prefix.startsWith('ao/') ||
      entry.prefix == 'audio' ||
      (entry.prefix == 'cplayer' && entry.text.contains('AO'));

  /// 退出应用前调用：停止记录并等待已有内容写入完成
  Future<void> close() {
    if (_closed) return _writing;
    log('exit');
    _closed = true;
    for (final entry in _verbose.values) {
      entry.logs.cancel();
    }
    _verbose.clear();
    _player = null;
    return flush();
  }

  /// 把累积的内容追加写入文件
  Future<void> flush() {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (_buffer.isEmpty) return _writing;
    final text = _buffer.toString();
    _buffer.clear();
    return _writing = _writing.then((_) => _write(text)).catchError((_) {});
  }

  Future<void> _write(String text) async {
    final file = File(filePath);
    var size = _size;
    if (size == null) {
      await Directory(directory).create(recursive: true);
      size = await file.exists() ? await file.length() : 0;
    }
    if (size > 0 && size + text.length > _maxBytes) {
      final backup = File(_backupPath);
      if (await backup.exists()) await backup.delete();
      await file.rename(_backupPath);
      size = 0;
    }
    await file.writeAsString(text, mode: FileMode.append, flush: true);
    _size = size + text.length;
  }

  /// 桌面端在文件管理器中打开日志所在的文件夹
  Future<void> openDirectory() async {
    await flush();
    await Directory(directory).create(recursive: true);
    await PathUtils.openDir(directory);
  }

  /// 系统分享日志文件（含备份）
  Future<void> share() async {
    await flush();
    final files = [
      for (final path in [_backupPath, filePath])
        if (File(path).existsSync()) XFile(path, mimeType: 'text/plain'),
    ];
    if (files.isEmpty) {
      SmartDialog.showToast('暂无诊断记录');
      return;
    }
    try {
      await SharePlus.instance.share(ShareParams(files: files));
    } catch (e) {
      SmartDialog.showToast(e.toString());
    }
  }
}
