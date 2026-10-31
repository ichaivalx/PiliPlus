import 'dart:math' show max, min;

/// 跟随端的倍速微调：输出相对倍速（1 为原速），由三部分组成
/// - 频差：两端音频时钟的长期速率差，按偏差积分学习，进入死区后保留；
/// - 位置修正：按当前偏差比例追赶，偏差在 [_deadbandMs] 以内不修正；
/// - 偏移移动：用户改变延迟偏移后，按改变量开环移动到新位置，不受死区限制。
///
/// 改变倍速后音频输出管线中仍有按旧倍速排队的声音，读到的位置在约一个输出延迟
/// 内会出现与倍速变化成正比的瞬态，期间（含开环移动期间）不更新修正
class LinkedSpeedControl {
  /// 位置修正的时间常数：偏差 e 时修正 e / τ
  static const _tauSeconds = 8.0;

  /// 频差学习的积分增益，取临界阻尼 Ki = (1/τ)² / 4
  static const _integralGain = 1 / (_tauSeconds * _tauSeconds * 4);

  /// 偏差在此以内不做位置修正，只由频差保持；约为滤波后读数噪声的两倍
  static const _deadbandMs = 1.0;

  /// 位置修正与频差的上限
  static const _maxProportional = 0.005;
  static const _maxIntegral = 0.002;

  /// 积分时单次计入的偏差上限，避免大偏差期间积累过多
  static const _maxIntegralErrorMs = 5.0;

  /// 偏差超过此值时按较快的速率追赶，此时不学习频差
  static const _coarseMs = 20.0;
  static const _coarseTauSeconds = 2.0;
  static const _maxCoarse = 0.04;

  /// 闭环修正（频差与位置修正之和）按此步长取整，变化不足一步时不改倍速
  static const step = 0.0001;

  /// 开环移动：按约 [_shiftSeconds] 完成，倍速改变量在上下限之间
  static const _shiftSeconds = 1.0;
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

  int? _lastAt;
  int _holdUntil = 0;

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

  /// 已按 [previous] → [current] 改变倍速；按步数比较，避免浮点误差漏判
  void onApplied(double previous, double current, int now) {
    if (((current - previous).abs() / step).round() >= _holdSteps) {
      _holdUntil = now + holdUs;
    }
  }

  /// 播放未推进（缓冲）：其间开环移动不计入，恢复后从下次更新起重新计时
  void suspend() {
    _lastAt = null;
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
    final last = _lastAt;
    _lastAt = now;
    final elapsed = last == null ? 0 : now - last;
    final dt = min(elapsed, _maxDtUs);
    // 上次更新以来开环移动的量，按实际播放的时长结算
    if (_shift != 0 && elapsed > 0) {
      final moved = -_shift * rate * elapsed;
      _pendingUs = _pendingUs > 0
          ? max(0.0, _pendingUs - moved)
          : min(0.0, _pendingUs - moved);
    }
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
