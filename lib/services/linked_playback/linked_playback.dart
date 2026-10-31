import 'dart:io' show Platform;

import 'package:PiliPlus/services/linked_playback/desktop_volume.dart';
import 'package:PiliPlus/services/linked_playback/diagnostics.dart';
import 'package:PiliPlus/services/linked_playback/follower.dart';
import 'package:PiliPlus/services/linked_playback/leader.dart';
import 'package:PiliPlus/services/linked_playback/models.dart';
import 'package:PiliPlus/services/linked_playback/target.dart';
import 'package:PiliPlus/services/shutdown_timer_service.dart';
import 'package:PiliPlus/utils/device_utils.dart';
import 'package:PiliPlus/utils/permission_handler.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
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
  static const _offsetKey = 'linkedPlaybackFollowerOffsetUs';
  static const _syncKey = 'linkedPlaybackSync';
  static const _deviceIdKey = 'linkedPlaybackDeviceId';
  static const _startBiasKey = 'linkedPlaybackStartBias';
  static const _seekCostKey = 'linkedPlaybackSeekCost';
  static const _coldSeekCostKey = 'linkedPlaybackColdSeekCost';
  static const _seekModeKey = 'linkedPlaybackSeekMode';
  static const _lastLeaderKey = 'linkedPlaybackLastLeader';
  static const _volumeModeKey = 'linkedPlaybackVolumeMode';
  static const _volumeOffsetKey = 'linkedPlaybackVolumeOffset';
  static const _volumeLevelKey = 'linkedPlaybackVolumeLevel';

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

  /// 主控播放中拖动进度时的同步方式，以主控的设置为准
  final Rx<LinkedSeekMode> seekMode = Rx<LinkedSeekMode>(
    LinkedSeekMode.values[GStorage.setting.get(_seekModeKey, defaultValue: 0)
        as int],
  );

  void setSeekMode(LinkedSeekMode value) {
    seekMode.value = value;
    GStorage.setting.put(_seekModeKey, value.index);
  }

  /// 延迟偏移的最小调节单位（微秒）
  static const offsetStepUs = 500;

  /// 跟随端：本机的延迟偏移（微秒），正值使本机相对主控延后；各跟随端分别
  /// 设置，主控可调节各跟随端的
  final RxInt offsetUs = RxInt(
    GStorage.setting.get(_offsetKey, defaultValue: 0) as int,
  );

  /// 主控：底栏与设置页当前调节的跟随端，音量与延迟偏移共用
  final RxnString _selectedPeerId = RxnString();

  /// 主控：可调节音量与延迟偏移的在线跟随端
  List<LinkedPeerInfo> get adjustablePeers => [
    for (final peer in peers)
      if (peer.state != LinkedPeerState.offline &&
          peer.volume != null &&
          peer.offsetUs != null)
        peer,
  ];

  /// 主控：当前调节的跟随端，未选择或所选已离线时为第一台
  LinkedPeerInfo? get selectedPeer {
    final list = adjustablePeers;
    final id = _selectedPeerId.value;
    for (final peer in list) {
      if (peer.id == id) return peer;
    }
    return list.firstOrNull;
  }

  void selectPeer(String id) => _selectedPeerId.value = id;

  /// 当前调节的延迟偏移：跟随端为本机的，主控为当前跟随端的
  int? get currentOffsetUs => role.value == LinkedRole.follower
      ? offsetUs.value
      : selectedPeer?.offsetUs;

  /// 跟随端：本机的音量设置与当前音量
  final Rx<LinkedVolume> volume = Rx<LinkedVolume>(
    LinkedVolume(
      mode:
          LinkedVolumeMode.values[GStorage.setting.get(
                _volumeModeKey,
                defaultValue: 0,
              )
              as int],
      offset: GStorage.setting.get(_volumeOffsetKey, defaultValue: 0) as int,
      level:
          GStorage.setting.get(_volumeLevelKey, defaultValue: 0.5) as double,
    ),
  );

  /// 主控的系统媒体音量；跟随端为已连接主控的
  final RxnDouble leaderVolume = RxnDouble();

  /// 启动失败的原因
  final RxnString error = RxnString();

  /// 主控：跟随端（含离线的）
  final RxList<LinkedPeerInfo> peers = <LinkedPeerInfo>[].obs;

  /// 跟随端：已连接的主控地址、本机实测偏差与往返时间
  final RxnString leader = RxnString();
  final RxnDouble driftMs = RxnDouble();
  final RxnDouble rttMs = RxnDouble();

  /// 最近加载内容的页面及其内容（为空表示不支持联动），会话启动时据此接管
  final Rxn<LinkedContent> current = Rxn<LinkedContent>();
  LinkedTarget? _currentTarget;

  /// 页面登记、释放播放内容的代次：发出请求后有其他页面登记过（如打开了视频），
  /// 请求返回时不应再登记
  int get epoch => _epoch;
  int _epoch = 0;

  /// 最近登记播放内容的是 [target]，或已无有效的登记（登记的页面已不再持有播放器）
  bool isCurrentOwner(LinkedTarget target) {
    final current = _currentTarget;
    return current == null || identical(current, target) || !current.isActive;
  }

  /// 最上层页面发起新的播放请求：取得播放归属，此后其他页面的续播不再登记
  void claim(LinkedTarget target) {
    final previous = _currentTarget;
    if (identical(previous, target)) return;
    current.value = null;
    _currentTarget = target;
    _epoch++;
    // 原页面进行中的共同起播（含等待自行起播）不再起播
    if (previous != null) {
      _leader?.supersede(previous);
    }
    _abandonHandedBack();
    _syncDesktopVolume();
  }

  /// 页面继续播放已加载的内容（未经加载流程，如返回听视频页继续播放）：
  /// 成为联动的内容
  void resume(LinkedContent? content, LinkedTarget target) {
    if (identical(_currentTarget, target) &&
        (current.value?.isSame(content) ?? content == null)) {
      return;
    }
    final switched = !identical(_currentTarget, target);
    current.value = content;
    _currentTarget = target;
    _epoch++;
    _abandonHandedBack();
    _leader?.takeOver(content, target);
    _follower?.adopt(target);
    if (switched) _syncDesktopVolume();
  }

  /// 页面交出播放器（未交给小窗，小窗接管时归属不变）：其进行中的共同起播
  /// （含等待自行起播）作废，不再起播
  void yieldTarget(LinkedTarget target) {
    _leader?.yieldTarget(target);
    _handedBack?.supersede(target);
  }

  /// 关闭联动时归还给本机、仍在等待加载完成后自行起播的会话
  LeaderSession? _handedBack;

  /// 其他页面开始播放或加载：归还的自行起播不再进行
  void _abandonHandedBack() {
    _handedBack?.abandon();
    _handedBack = null;
  }

  LeaderSession? _leader;
  FollowerSession? _follower;

  /// 开关与角色的切换依次执行
  Future<void> _switching = Future.value();

  /// 前台服务已按此文本运行；为空表示未运行，需要启动
  String? _serviceText;
  bool _serviceFailed = false;

  /// 应用启动后调用，已开启时开始运行
  void init() {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'screenOn':
          wake();
        case 'volume':
          if (call.arguments case {
            'v': final num value,
            'self': final bool self,
          }) {
            _onSystemVolume(value.toDouble(), self: self);
          }
      }
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
  bool get isFollowing => _follower?.isFollowing ?? _exitingAsFollower;

  /// 定时退出时会话已结束，退出前的进度同步仍按跟随端处理（不上报历史）
  bool _exitingAsFollower = false;

  /// 正在与对端一起播放，熄屏、后台时不暂停
  bool get holdsPlayback =>
      syncOn.value &&
      ((_leader?.hasPeers ?? false) || (_follower?.isFollowing ?? false));

  /// 本机开始播放的操作在播放器出声前调用：主控需要与跟随端共同起播时由联动接管，
  /// 调用方不再播放；返回是否已接管
  bool takePlay(LinkedTarget target) => _leader?.takePlay(target) ?? false;

  /// 页面发起定位（拖动进度、快进快退等）时、定位开始前调用：主控据此区分页面的
  /// 再次定位与联动自身的定位
  void noteSeek(LinkedTarget target) => _leader?.noteSeek(target);

  /// 页面加载内容前调用，[content] 为空表示该内容不支持联动；[autoplay]
  /// 为页面当前是否许可自动播放，共同起播前复核。返回非空时本次加载由联动播放接管
  LinkedLoad? gateLoad(
    LinkedContent? content,
    LinkedTarget target, {
    required bool Function() autoplay,
    required ShutdownLoad load,
  }) {
    final switched = !identical(_currentTarget, target);
    current.value = content;
    _currentTarget = target;
    _epoch++;
    _abandonHandedBack();
    if (switched) _syncDesktopVolume();
    if (_leader case final leader?) {
      return leader.gateLoad(content, target, autoplay: autoplay, load: load);
    }
    return _follower?.gateLoad(content, target, load: load);
  }

  /// 桌面端：页面的播放器创建完成后调用（新播放器按保存的音量初始化）
  void onPlayerCreated(LinkedTarget target) {
    if (identical(target, _currentTarget)) _syncDesktopVolume();
  }

  /// 桌面端：播放目标切换或其播放器创建后，本机音量与联动状态重新一致：跟随端
  /// 重新应用当前音量模式下的目标音量，主控重新采样有效音量并发布
  void _syncDesktopVolume() {
    if (!PlatformUtils.isDesktop) return;
    final target = _currentTarget;
    if (target == null || !target.isActive) return;
    final volume = LinkedDesktopVolume.current(target);
    if (_leader case final leader?) {
      if (leaderVolume.value == volume) return;
      leaderVolume.value = volume;
      leader.onLocalVolume(volume);
    } else {
      _follower?.reapplyVolume(volume);
    }
  }

  /// 页面关闭时调用
  void releaseTarget(LinkedTarget target) {
    if (identical(_currentTarget, target)) {
      current.value = null;
      _currentTarget = null;
      _epoch++;
    }
    _leader?.releaseTarget(target);
    _handedBack?.releaseTarget(target);
    _follower?.releaseTarget(target);
  }

  /// 页面加载内容失败
  void loadFailed(LinkedKind kind, int cid, String reason) {
    _follower?.loadFailed(kind, cid, reason);
  }

  /// 亮屏、回到前台、用户操作时确认连接，断开时立即重连
  void wake() {
    _follower?.wake();
    // 前台服务此前启动失败时重试
    _updateService();
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

  /// 设置当前调节的延迟偏移（跟随端为本机，主控为当前跟随端），取整到
  /// [offsetStepUs]
  void setOffset(int value) {
    final us = (value / offsetStepUs).round() * offsetStepUs;
    if (role.value == LinkedRole.leader) {
      if (selectedPeer case final peer?) _leader?.setOffset(peer.id, us);
    } else if (_saveOffset(us)) {
      _follower?.updateOffset(us);
    }
  }

  /// 在当前调节的延迟偏移上增减 [deltaUs]
  void adjustOffset(int deltaUs) {
    if (currentOffsetUs case final current?) setOffset(current + deltaUs);
  }

  bool _saveOffset(int us) {
    if (us == offsetUs.value) return false;
    offsetUs.value = us;
    GStorage.setting.put(_offsetKey, us);
    return true;
  }

  /// 设置跟随端的音量；主控设置 [id] 对应的跟随端，跟随端设置本机
  void setVolume(String? id, LinkedVolume value) {
    if (_leader case final leader?) {
      if (id != null) leader.setVolume(id, value);
    } else {
      _follower?.updateVolume(value);
    }
  }

  /// 桌面端：用户在本机调节播放器音量（音量条、手势、滚轮、快捷键、静音等）后
  /// 调用，主控通知跟随端，跟随端据此调整偏移或设定值；联动自身的设置不经此
  void onUserVolume(double volume) {
    if (!PlatformUtils.isDesktop) return;
    _onSystemVolume(volume.clamp(0.0, 1.0).toDouble(), self: false);
  }

  void _onSystemVolume(double value, {required bool self}) {
    if (_leader case final leader?) {
      leaderVolume.value = value;
      leader.onLocalVolume(value);
    } else {
      _follower?.onSystemVolume(value, self: self);
    }
  }

  /// 本机媒体音量：安卓为系统媒体音量，桌面端为播放器音量
  Future<double?> _getSystemVolume() async {
    if (PlatformUtils.isDesktop) {
      return LinkedDesktopVolume.current(_currentTarget);
    }
    if (!Platform.isAndroid) return null;
    try {
      return await _channel.invokeMethod<double>('getVolume');
    } catch (_) {
      return null;
    }
  }

  /// 设置本机媒体音量，不显示音量界面；返回设置后的实际音量
  Future<double?> _setSystemVolume(double value) async {
    if (PlatformUtils.isDesktop) {
      return LinkedDesktopVolume.set(value, _currentTarget);
    }
    if (!Platform.isAndroid) return null;
    try {
      return await _channel.invokeMethod<double>('setVolume', {'v': value});
    } catch (_) {
      return null;
    }
  }

  void _saveVolume(LinkedVolume value) {
    GStorage.setting
      ..put(_volumeModeKey, value.mode.index)
      ..put(_volumeOffsetKey, value.offset)
      ..put(_volumeLevelKey, value.level);
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

  /// 音频打断结束：联动跟随且被本机暂停时恢复当前跟随内容的播放器（打断期间可能
  /// 已切换到另一页面），返回是否已处理
  bool resumeInterrupted() => _follower?.resumeInterrupted() ?? false;

  void _setSync(bool on) {
    if (syncOn.value == on) return;
    syncOn.value = on;
    GStorage.setting.put(_syncKey, on);
  }

  Future<void> _onShutdown(bool exit) async {
    _leader?.pauseAll();
    _follower?.stopAll();
    if (!exit) return;
    // 退出应用：与其他退出方式共用同一次结束
    _exitingAsFollower = _follower?.isFollowing ?? false;
    await close();
  }

  /// 应用退出前调用（桌面端关闭窗口、托盘退出、定时关闭退出）：结束会话，等
  /// 停止消息发出，主控的跟随端随之停止跟随，再等诊断记录写完；重复调用等待
  /// 同一次结束
  Future<void> close() => _closing ??= _close();

  Future<void>? _closing;

  Future<void> _close() {
    final leader = _leader;
    final follower = _follower;
    _leader = null;
    _follower = null;
    _abandonHandedBack();
    return Future.wait<void>([
          if (leader != null) leader.dispose(),
          if (follower != null) follower.dispose(),
        ])
        .timeout(const Duration(seconds: 2), onTimeout: () => const <void>[])
        .whenComplete(linkedDiagnostics.close);
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
    // 关闭联动：主控进行中的共同起播归还本机按播放意图自行播放
    _stop(handBack: !enabled.value);
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
          syncOn: () => syncOn.value,
          onSyncRequest: (on) {
            _setSync(on);
            _leader?.applySync();
          },
          onPeersChanged: (list) => peers.value = list,
          seekTogether: () => seekMode.value == LinkedSeekMode.together,
        );
        if (_currentTarget case final target?) {
          session.adopt(current.value, target);
        }
        await session.start();
        if (await _getSystemVolume() case final value?) {
          leaderVolume.value = value;
          session.onLocalVolume(value);
        }
      } else {
        final session = _follower = FollowerSession(
          deviceId: _deviceId,
          deviceName: await _deviceName(),
          syncOn: () => syncOn.value,
          onSyncChanged: (on) {
            _setSync(on);
            _follower?.applySync();
          },
          offsetUs: offsetUs.value,
          onOffsetChanged: _saveOffset,
          startBiasUs:
              GStorage.setting.get(_startBiasKey, defaultValue: 0) as int,
          onStartBias: (value) => GStorage.setting.put(_startBiasKey, value),
          seekCostUs:
              GStorage.setting.get(_seekCostKey, defaultValue: 500000) as int,
          onSeekCost: (value) => GStorage.setting.put(_seekCostKey, value),
          coldSeekCostUs:
              GStorage.setting.get(_coldSeekCostKey, defaultValue: 2000000)
                  as int,
          onColdSeekCost: (value) =>
              GStorage.setting.put(_coldSeekCostKey, value),
          lastLeader: GStorage.setting.get(_lastLeaderKey) as String?,
          onLeader: (value) => GStorage.setting.put(_lastLeaderKey, value),
          leader: leader,
          driftMs: driftMs,
          rttMs: rttMs,
          volume: volume,
          leaderVolume: leaderVolume,
          setSystemVolume: _setSystemVolume,
          onVolumeSaved: _saveVolume,
        );
        if (await _getSystemVolume() case final value?) {
          volume.value = volume.value.copyWith(actual: value);
        }
        if (_currentTarget case final target?) {
          session.adopt(target);
        }
        await session.start();
      }
    } catch (e) {
      _stop();
      error.value = '启动失败：$e';
    }
    _updateService();
  });

  void _stop({bool handBack = false}) {
    error.value = null;
    _abandonHandedBack();
    if (_leader case final leader?) {
      leader.dispose(handBack: handBack);
      if (handBack) _handedBack = leader;
    }
    _leader = null;
    _follower?.dispose();
    _follower = null;
    peers.clear();
    leaderVolume.value = null;
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
    _channel
        .invokeMethod<void>('start', {'text': full})
        .then<void>(
          (_) {
            _serviceFailed = false;
          },
          onError: (_) {
            // 未运行：之后（如回到前台）重试
            if (_serviceText == full) _serviceText = null;
            if (!_serviceFailed) {
              _serviceFailed = true;
              SmartDialog.showToast('联动播放：后台保持服务启动失败，熄屏后可能中断');
            }
          },
        );
  }
}
