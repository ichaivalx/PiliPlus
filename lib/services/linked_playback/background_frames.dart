import 'dart:async';

import 'package:PiliPlus/services/linked_playback/clock.dart';
import 'package:flutter/scheduler.dart';

/// 应用在后台（熄屏）时框架停止产生帧，新打开的页面无法挂载、播放器无法初始化。
/// 跟随端打开内容期间由本机定时驱动帧（与启动时的 warm-up 帧相同，由 Dart
/// 定时器直接执行 build 与 layout，不依赖系统 vsync；无界面时引擎丢弃绘制结果），
/// 时间戳随实际时间前进，使页面转场动画得以完成。回到前台或到期后停止
abstract final class LinkedFrames {
  static const _interval = Duration(milliseconds: 16);

  static Timer? _timer;
  static int _untilUs = 0;
  static Duration _base = Duration.zero;
  static int _startUs = 0;

  /// 至少驱动帧到 [duration] 之后
  static void keep(Duration duration) {
    final binding = SchedulerBinding.instance;
    if (binding.framesEnabled) return;
    final until = LinkClock.nowUs + duration.inMicroseconds;
    if (until > _untilUs) _untilUs = until;
    if (_timer != null) return;
    // 接续最近一帧的时间戳，之后的系统帧时间戳总是更大
    _base = binding.currentSystemFrameTimeStamp;
    _startUs = LinkClock.nowUs;
    _timer = Timer.periodic(_interval, (_) => _pump());
  }

  /// 最多再驱动 [duration]
  static void finish(Duration duration) {
    final until = LinkClock.nowUs + duration.inMicroseconds;
    if (until < _untilUs) _untilUs = until;
  }

  static void _pump() {
    final binding = SchedulerBinding.instance;
    if (binding.framesEnabled || LinkClock.nowUs > _untilUs) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    if (binding.schedulerPhase != SchedulerPhase.idle) return;
    binding.handleBeginFrame(
      _base + Duration(microseconds: LinkClock.nowUs - _startUs),
    );
    // 与引擎的帧一样，在两个阶段之间执行微任务
    Timer.run(() {
      if (binding.schedulerPhase == SchedulerPhase.midFrameMicrotasks) {
        binding.handleDrawFrame();
      }
    });
  }
}
