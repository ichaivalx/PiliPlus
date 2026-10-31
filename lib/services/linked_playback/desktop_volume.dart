import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/services/linked_playback/target.dart';
import 'package:PiliPlus/utils/extension/num_ext.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';

/// 桌面端不控制系统音量，以 PiliPlus 播放器音量（设置中保存的桌面音量）代替
/// 系统媒体音量：0~1 对应 0~100%，超过 100% 的放大按 100% 计。用户在本机的
/// 调节由各操作入口经 [LinkedPlayback.onUserVolume] 通知，此处只供联动读写
abstract final class LinkedDesktopVolume {
  static double get value => Pref.desktopVolume.clamp(0.0, 1.0).toDouble();

  /// 联动设置本机播放器的音量（含 [target] 页面的播放器）并保存，不作为用户
  /// 调节通知；返回设置后的音量
  static double set(double volume, LinkedTarget? target) {
    final value = volume.clamp(0.0, 1.0).toDouble().toPrecision(3);
    GStorage.setting.put(SettingBoxKey.desktopVolume, value);
    PlPlayerController.instance?.setVolume(value, showIndicator: false);
    target?.setPlayerVolume(value);
    return value;
  }
}
