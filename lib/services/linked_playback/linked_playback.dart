import 'dart:io' show Platform;

import 'package:PiliPlus/services/linked_playback/follower.dart';
import 'package:PiliPlus/services/linked_playback/leader.dart';
import 'package:PiliPlus/services/linked_playback/models.dart';
import 'package:PiliPlus/services/linked_playback/target.dart';
import 'package:PiliPlus/services/shutdown_timer_service.dart';
import 'package:PiliPlus/utils/device_utils.dart';
import 'package:PiliPlus/utils/permission_handler.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter/widgets.dart' show AppLifecycleListener, WidgetsBinding;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';

export 'package:PiliPlus/services/linked_playback/models.dart';
export 'package:PiliPlus/services/linked_playback/target.dart';

final linkedPlayback = LinkedPlayback._();

/// 联动播放：同一局域网内一台设备（主控）播放的视频，其他设备（跟随端）
/// 自动打开并同步播放
class LinkedPlayback {
  LinkedPlayback._();

  static const _enabledKey = 'linkedPlaybackEnabled';
  static const _roleKey = 'linkedPlaybackRole';
  static const _offsetKey = 'linkedPlaybackOffset';
  static const _syncKey = 'linkedPlaybackSync';
  static const _deviceIdKey = 'linkedPlaybackDeviceId';
  static const _startBiasKey = 'linkedPlaybackStartBias';
  static const _lastLeaderKey = 'linkedPlaybackLastLeader';

  /// 保持熄屏、后台下连接与播放的前台服务
  static const _channel = MethodChannel('com.example.piliplus/linked_playback');

  final RxBool enabled = RxBool(
    GStorage.setting.get(_enabledKey, defaultValue: false) as bool,
  );
  final Rx<LinkedRole> role = Rx<LinkedRole>(
    LinkedRole.values[GStorage.setting.get(_roleKey, defaultValue: 0) as int],
  );

  /// 是否一起播放，连接始终保持
  final RxBool syncOn = RxBool(
    GStorage.setting.get(_syncKey, defaultValue: true) as bool,
  );

  /// 跟随端的延迟偏移（毫秒），正值使跟随端相对主控延后
  final RxInt offsetMs = RxInt(
    GStorage.setting.get(_offsetKey, defaultValue: 0) as int,
  );

  /// 启动失败的原因
  final RxnString error = RxnString();

  /// 主控：跟随端（含离线的）
  final RxList<LinkedPeerInfo> peers = <LinkedPeerInfo>[].obs;

  /// 跟随端：已连接的主控地址、本机实测偏差与往返时间
  final RxnString leader = RxnString();
  final RxnDouble driftMs = RxnDouble();
  final RxnDouble rttMs = RxnDouble();

  LeaderSession? _leader;
  FollowerSession? _follower;

  /// 开关与角色的切换依次执行
  Future<void> _switching = Future.value();

  String? _serviceText;

  /// 应用启动后调用，已开启时开始运行
  void init() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'screenOn') wake();
    });
    AppLifecycleListener(onResume: wake, onShow: wake);
    Connectivity().onConnectivityChanged.skip(1).listen((_) => _refresh());
    shutdownTimerService.addExpiredListener(_onShutdown);
    peers.listen((_) => _updateService());
    leader.listen((_) => _updateService());
    syncOn.listen((_) => _updateService());
    if (enabled.value) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _restart());
    }
  }

  /// 本机已连接对端
  bool get isConnected => _leader != null
      ? peers.any((e) => e.state != LinkedPeerState.offline)
      : leader.value != null;

  /// 正在跟随主控，本机不自行决定下一项、不上报历史、不跳过片段
  bool get isFollowing => _follower?.isFollowing ?? false;

  /// 正在与对端一起播放，熄屏、后台时不暂停
  bool get holdsPlayback =>
      syncOn.value &&
      ((_leader?.hasPeers ?? false) || (_follower?.isConnected ?? false));

  /// 页面加载内容前调用，[content] 为空表示该内容不支持联动；返回非空时
  /// 本次加载由联动播放接管
  LinkedLoad? gateLoad(
    LinkedContent? content,
    LinkedTarget target, {
    required bool autoplay,
  }) {
    if (_leader case final leader?) {
      return leader.gateLoad(content, target, autoplay: autoplay);
    }
    return _follower?.gateLoad(content, target);
  }

  /// 页面关闭时调用
  void releaseTarget(LinkedTarget target) {
    _leader?.releaseTarget(target);
    _follower?.releaseTarget(target);
  }

  /// 页面加载内容失败
  void loadFailed(LinkedKind kind, int cid, String reason) {
    _follower?.loadFailed(kind, cid, reason);
  }

  /// 亮屏、回到前台、用户操作时确认连接，断开时立即重连
  void wake() {
    _follower?.wake();
  }

  void _refresh() {
    _leader?.refresh();
    _follower?.refresh();
  }

  Future<void> setEnabled(bool value) async {
    if (value == enabled.value) return;
    if (value && !await _requestPermissions()) {
      SmartDialog.showToast('需要局域网权限才能使用联动播放');
      return;
    }
    enabled.value = value;
    GStorage.setting.put(_enabledKey, value);
    await _restart();
  }

  Future<void> setRole(LinkedRole value) async {
    if (value == role.value) return;
    role.value = value;
    GStorage.setting.put(_roleKey, value.index);
    await _restart();
  }

  void setOffset(int value) {
    offsetMs.value = value;
    GStorage.setting.put(_offsetKey, value);
    _leader?.updateOffset();
  }

  void setPeerVolume(String id, double volume) {
    _leader?.setVolume(id, volume);
  }

  /// 切换是否一起播放，两端共享；未连接时立即重连
  void toggleSync() {
    final on = !syncOn.value;
    _setSync(on);
    if (_leader case final leader?) {
      leader.applySync();
    } else if (_follower case final follower?) {
      follower
        ..applySync()
        ..requestSync(on);
    }
  }

  void _setSync(bool on) {
    if (syncOn.value == on) return;
    syncOn.value = on;
    GStorage.setting.put(_syncKey, on);
  }

  void _onShutdown() {
    _leader?.pauseAll();
    _follower?.stopAll();
  }

  Future<bool> _requestPermissions() async {
    if (!Platform.isAndroid) return true;
    // 常驻通知，未授权时服务仍可运行
    if (DeviceUtils.sdkInt >= 33) {
      await Permission.notification.request();
    }
    // targetSdk 37 起访问局域网需要授权，此前的系统无需申请
    if (DeviceUtils.sdkInt >= 37) {
      return (await Permission.accessLocalNetwork.request()).isGranted;
    }
    return true;
  }

  String get _deviceId {
    if (GStorage.setting.get(_deviceIdKey) case final String id) {
      return id;
    }
    final id = Utils.generateRandomString(16);
    GStorage.setting.put(_deviceIdKey, id);
    return id;
  }

  Future<String> _deviceName() async {
    try {
      if (Platform.isAndroid) {
        final info = await DeviceInfoPlugin().androidInfo;
        return '${info.brand} ${info.model}';
      }
      if (Platform.isIOS) {
        return (await DeviceInfoPlugin().iosInfo).name;
      }
    } catch (_) {}
    return Platform.localHostname;
  }

  Future<void> _restart() => _switching = _switching.then((_) async {
    _stop();
    if (!enabled.value) {
      _updateService();
      return;
    }
    try {
      if (!await _requestPermissions()) {
        error.value = '未获得局域网权限';
        _updateService();
        return;
      }
      if (role.value == LinkedRole.leader) {
        final session = _leader = LeaderSession(
          offsetMs: () => offsetMs.value,
          syncOn: () => syncOn.value,
          onSyncRequest: (on) {
            _setSync(on);
            _leader?.applySync();
          },
          onPeersChanged: (list) => peers.value = list,
        );
        await session.start();
      } else {
        final session = _follower = FollowerSession(
          deviceId: _deviceId,
          deviceName: await _deviceName(),
          syncOn: () => syncOn.value,
          onSyncChanged: (on) {
            _setSync(on);
            _follower?.applySync();
          },
          startBiasUs:
              GStorage.setting.get(_startBiasKey, defaultValue: 0) as int,
          onStartBias: (value) => GStorage.setting.put(_startBiasKey, value),
          lastLeader: GStorage.setting.get(_lastLeaderKey) as String?,
          onLeader: (value) => GStorage.setting.put(_lastLeaderKey, value),
          leader: leader,
          driftMs: driftMs,
          rttMs: rttMs,
        );
        await session.start();
      }
    } catch (e) {
      _stop();
      error.value = '启动失败：$e';
    }
    _updateService();
  });

  void _stop() {
    error.value = null;
    _leader?.dispose();
    _leader = null;
    _follower?.dispose();
    _follower = null;
    peers.clear();
  }

  /// 联动开启期间保持前台服务，通知显示当前状态
  void _updateService() {
    if (!Platform.isAndroid) return;
    if (_leader == null && _follower == null) {
      if (_serviceText != null) {
        _serviceText = null;
        _channel.invokeMethod('stop').catchError((_) {});
      }
      return;
    }
    final String text;
    if (_leader != null) {
      final online = peers
          .where((e) => e.state != LinkedPeerState.offline)
          .length;
      text = online == 0 ? '主控：等待跟随端连接' : '主控：已连接 $online 台跟随端';
    } else {
      text = leader.value == null ? '跟随：正在查找主控' : '跟随：已连接主控';
    }
    final full = syncOn.value ? text : '$text（未同步播放）';
    if (full == _serviceText) return;
    _serviceText = full;
    _channel.invokeMethod('start', {'text': full}).catchError((_) {
      SmartDialog.showToast('联动播放：后台保持服务启动失败，熄屏后可能中断');
    });
  }
}
