import 'package:PiliPlus/services/linked_playback/models.dart';
import 'package:get/get.dart';

/// 跟随端的系统媒体音量：跟随主控时为主控音量加偏移，独立时为设定值；
/// 本机按音量键的调整反推为偏移或设定值，保持两端一致
class FollowerVolume {
  FollowerVolume({
    required this.state,
    required this.leaderVolume,
    required this.setSystem,
    required this.onSaved,
    required this.onChanged,
  });

  final Rx<LinkedVolume> state;
  final RxnDouble leaderVolume;

  /// 设置系统媒体音量，返回设置后的实际音量
  final Future<double?> Function(double) setSystem;
  final void Function(LinkedVolume) onSaved;

  /// 设置或实际音量变化，需回报主控
  final void Function() onChanged;

  bool _connected = false;

  /// 已连接主控；跟随主控时在收到主控音量后恢复
  void connect() {
    _connected = true;
    _apply();
  }

  void disconnect() {
    _connected = false;
    leaderVolume.value = null;
  }

  void onLeaderVolume(double volume) {
    leaderVolume.value = volume;
    if (state.value.mode == LinkedVolumeMode.follow) {
      _apply();
    }
  }

  /// 本机换了播放器（桌面端切换播放目标），[actual] 为其当前音量：已连接时重新
  /// 应用当前模式下的目标音量，否则只记录实际音量
  void reapply(double actual) {
    state.value = state.value.copyWith(actual: actual);
    if (_connected && state.value.targetFor(leaderVolume.value) != null) {
      _apply();
    } else {
      onChanged();
    }
  }

  /// 主控或本机调整设置
  void update(LinkedVolume value) {
    _save(value.copyWith(actual: state.value.actual));
    _apply();
  }

  /// 系统媒体音量变化；[self] 为本机设置所致
  void onSystemVolume(double volume, {required bool self}) {
    final current = state.value.copyWith(actual: volume);
    if (self) {
      state.value = current;
    } else {
      // 用户在本机按音量键等调整
      switch (current.mode) {
        case LinkedVolumeMode.follow:
          final leader = leaderVolume.value;
          _save(
            leader == null
                ? current
                : current.copyWith(offset: ((volume - leader) * 100).round()),
          );
        case LinkedVolumeMode.independent:
          _save(current.copyWith(level: volume));
      }
    }
    onChanged();
  }

  void _save(LinkedVolume value) {
    state.value = value;
    onSaved(value);
  }

  Future<void> _apply() async {
    if (!_connected) return;
    final target = state.value.targetFor(leaderVolume.value);
    if (target == null) return;
    final actual = await setSystem(target);
    if (actual != null) {
      state.value = state.value.copyWith(actual: actual);
    }
    onChanged();
  }
}
