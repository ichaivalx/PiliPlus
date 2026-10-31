import 'dart:math' as math;
import 'dart:typed_data';

import 'package:PiliPlus/services/linked_playback/calibration_signal.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final random = math.Random(1);

  /// 近似正态的背景噪声
  double noise(double sigma) {
    var sum = 0.0;
    for (var i = 0; i < 12; i++) {
      sum += random.nextDouble();
    }
    return (sum - 6) * sigma;
  }

  Int16List record(int length, Map<int, (int slot, double gain)> chirps) {
    final mix = Float64List(length);
    for (var i = 0; i < length; i++) {
      mix[i] = noise(300);
    }
    for (final MapEntry(key: at, value: (slot, gain)) in chirps.entries) {
      final chirp = CalibrationSignal.chirp(slot);
      for (var i = 0; i < chirp.length; i++) {
        mix[at + i] += chirp[i] * gain * 16384;
      }
    }
    return Int16List.fromList([
      for (final value in mix) value.round().clamp(-32768, 32767).toInt(),
    ]);
  }

  test('finds the direct sound of each device despite a stronger echo', () {
    final samples = record(144000, {
      20000: (0, 0.3),
      // 晚 5ms 的更强反射
      20240: (0, 0.45),
      45234: (1, 0.05),
      70000: (2, 0.2),
    });
    final leader = detectChirp(samples, 0, 8000, 48800)!;
    expect(leader.index, closeTo(20000, 0.5));
    expect(leader.snr, greaterThan(CalibrationSignal.minSnr));
    final weak = detectChirp(samples, 1, 30834, 69234)!;
    expect(weak.index, closeTo(45234, 0.5));
    expect(weak.snr, greaterThan(CalibrationSignal.minSnr));
    final other = detectChirp(samples, 2, 55600, 94000)!;
    expect(other.index, closeTo(70000, 0.5));
  });

  test('reports no reliable detection without the device tone', () {
    final samples = record(144000, {70000: (2, 0.2)});
    final missing = detectChirp(samples, 3, 45600, 84000)!;
    expect(missing.snr, lessThan(CalibrationSignal.minSnr));
  });
}
