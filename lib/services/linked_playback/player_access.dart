import 'dart:async';
import 'dart:math' show min;

import 'package:PiliPlus/services/linked_playback/clock.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:media_kit/media_kit.dart';

/// 联动播放对 mpv 播放器的访问
abstract final class LinkedPlayer {
  /// 就绪需要的已缓冲时长
  static const _readyAheadUs = 1000000;

  /// 定位后的位置与目标相差在此范围内视为到位
  static const _seekToleranceUs = 300000;

  /// 等待就绪的上限，超时后按就绪处理，避免一端无法加载时一直等待
  static const _readyTimeoutUs = 10000000;

  /// 定时起播提前醒来的时间，剩余部分忙等以减少定时器误差
  static const _spinUs = 4000;

  static double? _seconds(Player player, String property) {
    if (player.disposed) return null;
    return double.tryParse(player.getProperty(property));
  }

  /// 已实际打开文件：页面发出打开命令后即视为已加载，打开失败时时长一直为零
  static bool isOpened(Player player) =>
      !player.disposed && player.state.duration > Duration.zero;

  /// 播放器实际的音量（0~1，静音时为 0）；播放器状态中的音量不随设置更新，
  /// 直接读取 mpv 属性
  static double? volume(Player player) {
    if (player.disposed) return null;
    final value = double.tryParse(player.getProperty('volume'));
    return value == null ? null : value / 100;
  }

  /// 当前画面位置（time-pos，微秒）
  static int? timePos(Player player) {
    final seconds = _seconds(player, 'time-pos');
    return seconds == null ? null : (seconds * 1e6).round();
  }

  /// 定位到 [targetUs] 并就绪后，实际起播位置超出目标的媒体时长（微秒）：有
  /// 视频时 mpv 让音频与定位后的第一帧画面同时开始（目标之后最近的一帧，相差
  /// 最多一帧），暂停中的画面位置即起播位置；没有视频时与目标一致。超出视为
  /// 到位的范围（低至约 3fps 的一帧）时多半是等待就绪超时、定位尚未完成，按 0 计
  static int landedUs(Player player, int targetUs) {
    final pos = timePos(player);
    if (pos == null) return 0;
    final landed = pos - targetUs;
    return landed >= 0 && landed <= _seekToleranceUs ? landed : 0;
  }

  /// 采样耗时超过此值时采样时刻不够准确，不用于精细对齐
  static const _maxSampleCostUs = 4000;

  /// 当前听到的位置及采样时刻（微秒）：audio-pts 已计入音频输出的延迟，
  /// 比按帧更新的 time-pos 更细；没有音频时退回 time-pos。[audio] 表示取自
  /// audio-pts，[cost] 为读取耗时，[fine] 表示可用于精细对齐
  static ({int at, int pos, bool audio, int cost, bool fine})? sample(
    Player player,
  ) {
    if (player.disposed) return null;
    final start = LinkClock.nowUs;
    var value = player.getProperty('audio-pts');
    final audio = value.isNotEmpty;
    if (!audio) {
      value = player.getProperty('time-pos');
    }
    final end = LinkClock.nowUs;
    final seconds = double.tryParse(value);
    if (seconds == null) return null;
    final cost = end - start;
    return (
      at: (start + end) ~/ 2,
      pos: (seconds * 1e6).round(),
      audio: audio,
      cost: cost,
      fine: audio && cost <= _maxSampleCostUs,
    );
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

  /// [targetUs] 位于当前位置之后的已缓冲范围内（且其后仍有就绪所需的缓冲），
  /// 定位无需重新取流
  static bool isBuffered(Player player, int targetUs) {
    final posUs = timePos(player);
    final cached = _seconds(player, 'demuxer-cache-time');
    if (posUs == null || cached == null) return false;
    return targetUs >= posUs - _seekToleranceUs &&
        targetUs <= (cached * 1e6).round() - _readyAheadUs;
  }

  /// 直接设置播放器的实际速度为倍速 [rate] 乘以联动的微调 [factor]，不改动页面
  /// 记录的倍速。微调以重采样实现，音调随之有同比例的微小变化：音调校正插入的
  /// scaletempo2 在速度 1 附近约 ±0.17% 内原样复制，速度并不改变，超出后也要等
  /// 累积偏差超出其搜索范围（约 16ms）才实际变速，而 audio-pts 按设定的速度推算，
  /// 读数与实际声音相差可达 16ms，恢复原样复制时又跳回实际位置。
  /// 原速时关闭音调校正，速度只经重采样，每次实际变化的只有速度，不会因速度与
  /// pitch 先后写入的中间状态插入 scaletempo2；其他倍速由 scaletempo2 按倍速变速，
  /// pitch 设为微调使微调部分改由重采样实现
  static void setSpeed(Player player, double rate, double factor) {
    if (player.disposed) return;
    final original = rate == 1;
    player
      ..setProperty('audio-pitch-correction', original ? 'no' : 'yes')
      ..setProperty('pitch', (original ? 1.0 : factor).toStringAsFixed(6))
      ..setProperty('speed', (rate * factor).toStringAsFixed(6));
  }

  /// 恢复播放器的速度为页面记录的倍速，音调校正恢复默认
  static void restoreSpeed(Player player) {
    if (player.disposed) return;
    player
      ..setProperty('audio-pitch-correction', 'yes')
      ..setProperty('pitch', '1.000000')
      ..setProperty('speed', player.state.rate.toStringAsFixed(6));
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
