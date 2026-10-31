import 'dart:math' show max, min;

/// 跟随端的倍速微调：输出相对倍速（1 为原速），由三部分组成
/// - 频差：两端音频时钟的长期速率差，按偏差积分学习，进入死区后保留；
/// - 位置修正：按当前偏差比例追赶，偏差在 [_deadbandMs] 以内不修正；
/// - 偏移移动：用户改变延迟偏移后，按改变量开环移动到新位置，不受死区限制。
///
/// 改变倍速后音频输出管线中仍有按旧倍速排队的声音，读到的位置在约一个输出延迟
/// 内会出现与倍速变化成正比的瞬态，期间（含开环移动期间）不更新修正
class LinkedSpeedControl {
  /// 位置修正的时间常数：偏差 e 时修正 e / τ。测量与执行的滞后（5 点中位数约
  /// 0.5s、倍速改变后的 0.75s 等待、输出缓冲）合计约 1~1.5s，在 1/τ 处的相位
  /// 滞后约 15°~20°，临界阻尼下仍有 55° 以上的相位裕度，不会振荡
  static const _tauSeconds = 4.0;

  /// 频差学习的积分增益，取临界阻尼 Ki = (1/τ)² / 4
  static const _integralGain = 1 / (_tauSeconds * _tauSeconds * 4);

  /// 偏差在此以内不做位置修正，只由频差保持；约为滤波后读数噪声的两倍
  static const _deadbandMs = 1.0;

  /// 位置修正的上限：略高于精细区内能达到的最大值（(10 - 1)ms / 4s = 0.225%），
  /// 只作保护；频差的上限按两端时钟可能的速率差，与 τ 无关
  static const _maxProportional = 0.0025;
  static const _maxIntegral = 0.002;

  /// 积分时单次计入的偏差上限（精细区的一半），避免较大偏差期间积累过多
  static const _maxIntegralErrorMs = 5.0;

  /// 偏差超过此值时按较快的速率追赶，此时不学习频差
  static const _coarseMs = 10.0;
  static const _coarseTauSeconds = 2.0;
  static const _maxCoarse = 0.04;

  /// 闭环修正（频差与位置修正之和）按此步长取整，变化不足一步时不改倍速
  static const step = 0.0001;

  /// 开环移动：按约 [_shiftSeconds]（一次采样间隔）完成，倍速改变量在上下限之间：
  /// 10ms 以内的改变约 0.25s 到位，更大的改变按上限尽快完成；下限使 0.5ms 的
  /// 改变也在一次采样间隔内完成
  static const _shiftSeconds = 0.25;
  static const _minShift = 0.002;
  static const _maxShift = 0.04;

  /// 倍速改变达到此值（按 [step] 计的步数）时等待管线瞬态过去
  static const _holdSteps = 10;
  static const holdUs = 750000;

  /// 频差积分时两次更新间隔的上限，超过时按此计（如采样中断后恢复）
  static const _maxDtUs = 500000;

  double _integral = 0;
  double _proportional = 0;

  /// 尚待开环移动的位置（微秒），正值表示本机需相对主控后退
  double _pendingUs = 0;
  double _shift = 0;

  /// 上次计时的时刻，暂停计时（缓冲、未播放）期间为空
  int? _lastAt;
  int _holdUntil = 0;

  /// 最近一次更新时的播放倍速，结算开环移动用
  double _rate = 1;

  double get integral => _integral;
  double get proportional => _proportional;
  double get pendingUs => _pendingUs;

  /// 当前应用的相对倍速
  double get factor =>
      1 + ((_integral + _proportional) / step).round() * step + _shift;

  /// 读数受倍速变化瞬态影响，不用于修正
  bool isHolding(int now) => _shift != 0 || now < _holdUntil;

  /// 延迟偏移增加 [deltaUs]（本机需后退同样的量）
  void shift(int deltaUs) {
    _pendingUs += deltaUs;
  }

  /// 已按 [previous] → [current] 改变倍速；按步数比较，避免浮点误差漏判。返回
  /// 是否开始等待瞬态：此前的读数已不反映新倍速下的状态，调用方应清空，否则
  /// 等待结束后滤波仍按旧读数修正而过冲
  bool onApplied(double previous, double current, int now) {
    if (((current - previous).abs() / step).round() < _holdSteps) return false;
    _holdUntil = now + holdUs;
    return true;
  }

  /// 播放停止推进（缓冲、未播放）：结算此前的开环移动并暂停计时
  void suspend(int now) {
    if (_lastAt == null) return;
    _settle(now);
    _lastAt = null;
  }

  /// 播放恢复推进：从此刻起计时
  void resume(int now) {
    _lastAt ??= now;
  }

  /// 结算上次计时以来开环移动的量（按实际播放的时长），返回经过的时长
  int _settle(int now) {
    final last = _lastAt;
    _lastAt = now;
    if (last == null) return 0;
    final elapsed = now - last;
    if (_shift != 0 && elapsed > 0) {
      final moved = -_shift * _rate * elapsed;
      _pendingUs = _pendingUs > 0
          ? max(0.0, _pendingUs - moved)
          : min(0.0, _pendingUs - moved);
    }
    return elapsed;
  }

  /// 停止修正（定位、跳转、暂停等），保留已学到的频差；[keepShift] 为 false 时
  /// 放弃未完成的开环移动（重新定位已按新偏移进行）
  void stop({bool keepShift = false}) {
    _proportional = 0;
    _lastAt = null;
    if (!keepShift) {
      _pendingUs = 0;
      _shift = 0;
    }
  }

  /// 换了主控：频差不再适用
  void reset() {
    stop();
    _integral = 0;
    _holdUntil = 0;
  }

  /// 每次采样后调用。[errorMs] 为滤波后的偏差（正值表示本机超前），[fine] 表示
  /// 读数可用于精细修正（两端都取自音频输出位置且采样耗时正常），[rate] 为当前
  /// 播放倍速
  void update({
    required double? errorMs,
    required bool fine,
    required double rate,
    required int now,
  }) {
    final dt = min(_settle(now), _maxDtUs);
    _rate = rate;
    if (_pendingUs.abs() >= 1) {
      final magnitude = _pendingUs.abs() / 1e6;
      // 按 0.25 秒后再次更新估计，不超过剩余量
      final shift = min(
        (magnitude / _shiftSeconds).clamp(_minShift, _maxShift).toDouble(),
        magnitude / (rate * 0.25),
      );
      _shift = _pendingUs > 0 ? -shift : shift;
      _proportional = 0;
      return;
    }
    if (_shift != 0) {
      _shift = 0;
      _pendingUs = 0;
      _holdUntil = now + holdUs;
      return;
    }
    if (errorMs == null || now < _holdUntil) return;
    final magnitude = errorMs.abs();
    if (magnitude > _coarseMs) {
      _proportional = (-errorMs / 1000 / _coarseTauSeconds)
          .clamp(-_maxCoarse, _maxCoarse)
          .toDouble();
      return;
    }
    if (!fine) {
      // 读数精度不足（无音频、采样耗时过长）：只保持已学到的频差
      _proportional = 0;
      return;
    }
    if (dt > 0) {
      final e = errorMs.clamp(-_maxIntegralErrorMs, _maxIntegralErrorMs);
      _integral = (_integral - _integralGain * e / 1000 * dt / 1e6)
          .clamp(-_maxIntegral, _maxIntegral)
          .toDouble();
    }
    final outside = magnitude - _deadbandMs;
    _proportional = outside <= 0
        ? 0.0
        : (-(errorMs.sign * outside) / 1000 / _tauSeconds)
              .clamp(-_maxProportional, _maxProportional)
              .toDouble();
  }
}
