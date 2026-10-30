import 'dart:async';
import 'dart:io' show Platform;

import 'package:PiliPlus/services/linked_playback/follower.dart';
import 'package:PiliPlus/services/linked_playback/leader.dart';
import 'package:PiliPlus/services/linked_playback/models.dart';
import 'package:PiliPlus/utils/device_utils.dart';
import 'package:PiliPlus/utils/permission_handler.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:flutter/widgets.dart' show WidgetsBinding;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';

export 'package:PiliPlus/services/linked_playback/models.dart';

final linkedPlayback = LinkedPlayback._();

/// 联动播放：同一局域网内一台设备（主控）播放的视频，其他设备（跟随端）
/// 自动打开并同步播放
class LinkedPlayback {
  LinkedPlayback._();

  static const _enabledKey = 'linkedPlaybackEnabled';
  static const _roleKey = 'linkedPlaybackRole';
  static const _offsetKey = 'linkedPlaybackOffset';

  final RxBool enabled = RxBool(
    GStorage.setting.get(_enabledKey, defaultValue: false) as bool,
  );
  final Rx<LinkedRole> role = Rx<LinkedRole>(
    LinkedRole.values[GStorage.setting.get(_roleKey, defaultValue: 0) as int],
  );

  /// 跟随端的延迟偏移（毫秒），正值使跟随端相对主控延后
  final RxInt offsetMs = RxInt(
    GStorage.setting.get(_offsetKey, defaultValue: 0) as int,
  );

  /// 启动失败的原因
  final RxnString error = RxnString();

  /// 主控：已连接的跟随端
  final RxList<LinkedPeerInfo> peers = <LinkedPeerInfo>[].obs;

  /// 跟随端：已连接的主控地址、本机实测偏差与往返时间
  final RxnString leader = RxnString();
  final RxnDouble driftMs = RxnDouble();
  final RxnDouble rttMs = RxnDouble();

  LeaderSession? _leader;
  FollowerSession? _follower;

  /// 开关与角色的切换依次执行
  Future<void> _switching = Future.value();

  /// 应用启动后调用，已开启时开始运行
  void init() {
    if (enabled.value) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _restart());
    }
  }

  /// 正在跟随主控，本机不自行决定下一项
  bool get isFollowing => _follower?.isConnected ?? false;

  /// 视频页加载内容前调用，[content] 为空表示该内容不支持联动；返回非空时
  /// 本次加载由联动播放接管
  LinkedLoad? gateLoad(LinkedContent? content, {required bool autoplay}) {
    if (_leader case final leader?) {
      return leader.gateLoad(content, autoplay: autoplay);
    }
    return _follower?.gateLoad(content);
  }

  Future<void> setEnabled(bool value) async {
    if (value == enabled.value) return;
    if (value && !await _requestPermission()) {
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

  Future<bool> _requestPermission() async {
    // targetSdk 37 起访问局域网需要授权，此前的系统无需申请
    if (Platform.isAndroid && DeviceUtils.sdkInt >= 37) {
      return (await Permission.accessLocalNetwork.request()).isGranted;
    }
    return true;
  }

  Future<void> _restart() => _switching = _switching.then((_) async {
    _stop();
    if (!enabled.value) return;
    try {
      if (!await _requestPermission()) {
        error.value = '未获得局域网权限';
        return;
      }
      if (role.value == LinkedRole.leader) {
        final session = _leader = LeaderSession(
          offsetMs: () => offsetMs.value,
          onPeersChanged: (list) => peers.value = list,
        );
        await session.start();
      } else {
        final session = _follower = FollowerSession(
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
  });

  void _stop() {
    error.value = null;
    _leader?.dispose();
    _leader = null;
    _follower?.dispose();
    _follower = null;
    peers.clear();
  }
}
