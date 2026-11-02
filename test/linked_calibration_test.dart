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

  Int16List record(
    int length,
    Map<int, (int slot, double gain)> chirps, {
    ChirpBand band = ChirpBand.high,
  }) {
    final mix = Float64List(length);
    for (var i = 0; i < length; i++) {
      mix[i] = noise(300);
    }
    for (final MapEntry(key: at, value: (slot, gain)) in chirps.entries) {
      final chirp = CalibrationSignal.chirp(slot, band: band);
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

  test('rejects a neighbouring device tone inside a silent device window', () {
    // 第 1 台静音，第 2 台的扫频音在其窗口内
    final samples = record(192000, {24000: (0, 0.3), 72000: (2, 0.4)});
    final wrong = detectChirp(samples, 1, 33600, 72000)!;
    expect(
      chirpIdentity(samples, 1, wrong.index, 3),
      lessThan(CalibrationSignal.minIdentity),
    );
    final right = detectChirp(samples, 2, 57600, 96000)!;
    expect(right.index, closeTo(72000, 0.5));
    expect(
      chirpIdentity(samples, 2, right.index, 3),
      greaterThan(CalibrationSignal.minIdentity),
    );
  });

  test('finds the direct low tone before stronger later reverberation', () {
    final samples = record(144000, {
      30000: (0, 0.2),
      // 晚 25ms 的更强混响，按中高频的判定会被当作直达声
      31200: (0, 0.35),
    }, band: ChirpBand.bass);
    final found = detectChirp(
      samples,
      0,
      10800,
      49200,
      band: ChirpBand.bass,
    )!;
    expect(found.index, closeTo(30000, 24));
    expect(found.snr, greaterThan(CalibrationSignal.minSnr));
  });

  test('reports no reliable low tone without the device tone', () {
    final samples = record(144000, {}, band: ChirpBand.lowMid);
    final missing = detectChirp(
      samples,
      0,
      70800,
      109200,
      band: ChirpBand.lowMid,
    )!;
    expect(missing.snr, lessThan(CalibrationSignal.minSnr));
  });

  test('takes the low-mid tone instead of a missing bass tone', () {
    int samplesOf(int us) => us * CalibrationPlan.sampleRate ~/ 1000000;
    // 低音区没有输出的设备，三轮都只有中低频扫频音
    const rounds = [60000, 120024, 179976];
    final samples = record(240000, {
      for (final at in rounds) at: (0, 0.3),
    }, band: ChirpBand.lowMid);
    for (final lowMid in rounds) {
      final high = lowMid - samplesOf(ChirpBand.lowMid.offsetUs);
      final bassAt = high + samplesOf(ChirpBand.bass.offsetUs);
      // 低音区的模板与中低频扫频音的一端部分对上，峰值足够突出
      final bass = detectChirp(
        samples,
        0,
        bassAt - samplesOf(400000),
        bassAt + samplesOf(400000),
        band: ChirpBand.bass,
      )!;
      expect(bass.snr, greaterThan(CalibrationSignal.minSnr));
      expect(
        chirpBandIdentity(samples, 0, bass.index, band: ChirpBand.bass),
        lessThan(CalibrationSignal.minBandIdentity),
      );
      final found = detectChirp(
        samples,
        0,
        lowMid - samplesOf(400000),
        lowMid + samplesOf(400000),
        band: ChirpBand.lowMid,
      )!;
      expect(found.index, closeTo(lowMid, 24));
      expect(found.snr, greaterThan(CalibrationSignal.minSnr));
      expect(
        chirpBandIdentity(samples, 0, found.index, band: ChirpBand.lowMid),
        greaterThan(CalibrationSignal.minBandIdentity),
      );
    }
  });
}
