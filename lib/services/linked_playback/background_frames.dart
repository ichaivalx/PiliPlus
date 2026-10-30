import 'dart:async';

import 'package:PiliPlus/services/linked_playback/clock.dart';
import 'package:flutter/scheduler.dart';

/// 应用在后台（熄屏）时框架停止产生帧，新打开的页面无法挂载、播放器无法初始化。
/// 跟随端打开内容期间登记待完成任务，其间应用处于后台时由本机定时驱动帧
/// （与 warm-up 帧相同，由 Dart 定时器直接执行 build 与 layout，不依赖系统
/// vsync；无界面时引擎丢弃绘制结果）。时间戳随实际时间前进，使页面转场动画
/// 得以完成：GetX 的页面转场时长固定，按路由名打开页面时无法改为零时长，
/// 而 warm-up 帧的时间戳不前进，转场会停住
abstract final class LinkedFrames {
  static const _interval = Duration(milliseconds: 16);

  static Timer? _timer;
  static int _untilUs = 0;

  /// 正在驱动：时间戳接续开始驱动前的最后一帧，之后的系统帧时间戳总是更大
  static bool _pumping = false;
  static Duration _base = Duration.zero;
  static int _startUs = 0;

  /// 登记待完成的任务，至少到 [duration] 之后
  static void keep(Duration duration) {
    final until = LinkClock.nowUs + duration.inMicroseconds;
    if (until > _untilUs) _untilUs = until;
    _timer ??= Timer.periodic(_interval, (_) => _tick());
  }

  /// 任务已完成，最多再驱动 [duration]
  static void finish(Duration duration) {
    final until = LinkClock.nowUs + duration.inMicroseconds;
    if (until < _untilUs) _untilUs = until;
  }

  static void _tick() {
    final now = LinkClock.nowUs;
    if (now > _untilUs) {
      _timer?.cancel();
      _timer = null;
      _pumping = false;
      return;
    }
    final binding = SchedulerBinding.instance;
    // 前台由引擎产生帧
    if (binding.framesEnabled) {
      _pumping = false;
      return;
    }
    if (binding.schedulerPhase != SchedulerPhase.idle) return;
    if (!_pumping) {
      _pumping = true;
      _base = binding.currentSystemFrameTimeStamp;
      _startUs = now;
    }
    // 两个阶段在同一任务内完成：引擎的帧同样在一个任务内完成，二者不会交错
    binding
      ..handleBeginFrame(_base + Duration(microseconds: now - _startUs))
      ..handleDrawFrame();
  }
}
