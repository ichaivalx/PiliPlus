import 'dart:async';
import 'dart:math' show min;

import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/data_status.dart';
import 'package:PiliPlus/services/linked_playback/clock.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:media_kit/media_kit.dart';

/// 联动播放对视频播放器的访问
abstract final class LinkedPlayer {
  /// 就绪需要的已缓冲时长
  static const _readyAheadUs = 1000000;

  /// 定位后的位置与目标相差在此范围内视为到位
  static const _seekToleranceUs = 300000;

  /// 等待就绪的上限，超时后按就绪处理，避免一端无法加载时一直等待
  static const _readyTimeoutUs = 10000000;

  /// 定时起播提前醒来的时间，剩余部分忙等以减少定时器误差
  static const _spinUs = 4000;

  /// 已加载 [cid] 的视频播放器
  static PlPlayerController? withContent(int? cid) {
    final controller = PlPlayerController.instance;
    if (cid == null ||
        controller == null ||
        controller.isLive ||
        controller.cid != cid ||
        !controller.dataStatus.loaded) {
      return null;
    }
    final player = controller.videoPlayerController;
    if (player == null || player.disposed) {
      return null;
    }
    return controller;
  }

  static double? _seconds(Player player, String property) {
    if (player.disposed) return null;
    return double.tryParse(player.getProperty(property));
  }

  /// 当前画面位置（time-pos，微秒）
  static int? timePos(Player player) {
    final seconds = _seconds(player, 'time-pos');
    return seconds == null ? null : (seconds * 1e6).round();
  }

  /// 当前听到的位置及采样时刻（微秒）：audio-pts 已计入音频输出的延迟，
  /// 比按帧更新的 time-pos 更细；没有音频时退回 time-pos
  static ({int at, int pos})? sample(Player player) {
    if (player.disposed) return null;
    final start = LinkClock.nowUs;
    var value = player.getProperty('audio-pts');
    if (value.isEmpty) {
      value = player.getProperty('time-pos');
    }
    final end = LinkClock.nowUs;
    final seconds = double.tryParse(value);
    if (seconds == null) return null;
    return (at: (start + end) ~/ 2, pos: (seconds * 1e6).round());
  }

  /// 等待文件打开且起始定位完成，返回当前画面位置；[isCurrent] 为 false 时
  /// 放弃并返回 null
  static Future<int?> waitLoaded(
    Player player,
    bool Function() isCurrent,
  ) async {
    final deadline = LinkClock.nowUs + _readyTimeoutUs;
    // 刚发出的定位命令可能尚未开始执行
    await Future<void>.delayed(const Duration(milliseconds: 100));
    while (isCurrent() && !player.disposed) {
      final posUs = timePos(player);
      if (posUs != null &&
          player.state.duration > Duration.zero &&
          player.getProperty('seeking') != 'yes') {
        return posUs;
      }
      if (LinkClock.nowUs > deadline) {
        return posUs ?? 0;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return null;
  }

  /// 等待定位到 [targetUs] 完成且缓冲足够；[isCurrent] 为 false 时放弃并返回 false
  static Future<bool> waitReady(
    Player player,
    int targetUs,
    bool Function() isCurrent,
  ) async {
    final deadline = LinkClock.nowUs + _readyTimeoutUs;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    while (isCurrent() && !player.disposed) {
      if (_isReady(player, targetUs) || LinkClock.nowUs > deadline) {
        return true;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return false;
  }

  static bool _isReady(Player player, int targetUs) {
    final durationUs = player.state.duration.inMicroseconds;
    if (durationUs <= 0 || player.getProperty('seeking') == 'yes') {
      return false;
    }
    final posUs = timePos(player);
    if (posUs == null || (posUs - targetUs).abs() > _seekToleranceUs) {
      return false;
    }
    if (player.getProperty('demuxer-cache-idle') == 'yes') {
      return true;
    }
    final cached = _seconds(player, 'demuxer-cache-time');
    if (cached == null) return false;
    return (cached * 1e6).round() - posUs >=
        min(_readyAheadUs, durationUs - posUs - 100000);
  }

  /// 直接设置播放器的实际速度，不改动页面记录的倍速
  static void setSpeed(Player player, double speed) {
    if (player.disposed) return;
    player.setProperty('speed', speed.toStringAsFixed(6));
  }

  /// 联动期间以音频为主时钟，结束后恢复设置中的值
  static void setVideoSync(Player player, {required bool linked}) {
    if (player.disposed) return;
    player.setProperty('video-sync', linked ? 'audio' : Pref.videoSync);
  }

  /// 在本机时刻 [atUs] 执行 [action]
  static Timer scheduleAt(int atUs, void Function() action) {
    final wait = atUs - _spinUs - LinkClock.nowUs;
    return Timer(Duration(microseconds: wait > 0 ? wait : 0), () {
      while (LinkClock.nowUs < atUs) {}
      action();
    });
  }
}
