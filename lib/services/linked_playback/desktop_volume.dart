import 'dart:async';

import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/services/linked_playback/target.dart';
import 'package:PiliPlus/utils/extension/num_ext.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';

/// 桌面端不控制系统音量，以 PiliPlus 播放器音量（设置中保存的桌面音量）代替
/// 系统媒体音量：0~1 对应 0~100%，超过 100% 的放大按 100% 计
abstract final class LinkedDesktopVolume {
  /// 本机设置时写入的值，随后保存的同一值不视为用户调整
  static double? _written;
  static StreamSubscription<Object?>? _subscription;

  static double get value => Pref.desktopVolume.clamp(0.0, 1.0).toDouble();

  /// 用户调整播放器音量（保存时）调用 [onChanged]
  static void listen(void Function(double volume) onChanged) {
    _subscription?.cancel();
    _subscription = GStorage.setting
        .watch(key: SettingBoxKey.desktopVolume)
        .listen((event) {
          final saved = event.value;
          if (saved is! num) return;
          final volume = saved.toDouble();
          final written = _written;
          if (written != null && (volume - written).abs() < 0.001) return;
          _written = null;
          onChanged(volume.clamp(0.0, 1.0).toDouble());
        });
  }

  /// 设置本机播放器的音量（含 [target] 页面的播放器），返回设置后的音量
  static double set(double volume, LinkedTarget? target) {
    final value = volume.clamp(0.0, 1.0).toDouble().toPrecision(3);
    _written = value;
    GStorage.setting.put(SettingBoxKey.desktopVolume, value);
    PlPlayerController.instance?.setVolume(value, showIndicator: false);
    target?.setPlayerVolume(value);
    return value;
  }
}
