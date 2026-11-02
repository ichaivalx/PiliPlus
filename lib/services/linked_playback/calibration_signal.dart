import 'dart:math' as math;
import 'dart:typed_data';

/// 一次声学校准的安排，各端共用：所有设备在约定时刻 [startAt]（主控时钟，
/// 微秒）同时开始播放各自的测试音文件，设备 [slot] 第 r 轮各频段的扫频音位于
/// 文件中 [chirpAtUs] 处；各设备、各轮依次间隔 [spacingUs]，互不重叠，最后的
/// 低频扫频音结束后留 0.4s 待其混响衰减
class CalibrationPlan {
  const CalibrationPlan({
    required this.id,
    required this.devices,
    required this.startAt,
    this.volume,
  });

  static const rounds = 3;
  static const sampleRate = 48000;
  static const spacingUs = 1200000;

  /// 文件开头的静音，等待音频输出启动稳定
  static const leadUs = 400000;

  final int id;

  /// 参与的设备数，主控为第 0 台
  final int devices;
  final int startAt;

  /// 校准期间各设备临时提高到的音量（0~1），只在原音量更低时提高；为空时不调整
  final double? volume;

  int chirpAtUs(int slot, int round, {ChirpBand band = ChirpBand.high}) =>
      leadUs + slot * spacingUs + round * devices * spacingUs + band.offsetUs;

  int get durationUs => leadUs + rounds * devices * spacingUs;

  Map<String, Object?> toJson() => {
    'id': id,
    'devices': devices,
    'start': startAt,
    'volume': ?volume,
  };

  static CalibrationPlan? fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final devices = json['devices'];
    final start = json['start'];
    final volume = json['volume'];
    if (id is! int || devices is! int || start is! int || devices < 1) {
      return null;
    }
    return CalibrationPlan(
      id: id,
      devices: devices,
      startAt: start,
      volume: volume is num ? volume.toDouble() : null,
    );
  }
}

/// 扫频音的频段：中高频测各设备的声学延迟；两段低频测各设备低频相对中高频
/// 额外的延迟（扬声器、低音处理的群延迟），每台设备取能可靠测出的较低一段。
/// 低频带宽窄，加长时长保证相关峰的信噪比，两端过渡加长以免爆音；同一频段
/// 相邻设备方向相反，同向的相隔两台（2.4s）以上
enum ChirpBand {
  high(
    offsetUs: 0,
    durationUs: 80000,
    taperUs: 5000,
    lookbackUs: 15000,
    earliestRatio: 0.5,
    sweeps: [
      (1500.0, 4500.0),
      (4500.0, 1500.0),
      (2000.0, 6000.0),
      (6000.0, 2000.0),
      (1200.0, 3600.0),
      (3600.0, 1200.0),
    ],
  ),

  /// 低音区：显示器、音箱的低音处理多在此段（时宽带宽积 51）
  bass(
    offsetUs: 200000,
    durationUs: 300000,
    taperUs: 20000,
    lookbackUs: _lowLookbackUs,
    earliestRatio: _lowEarliestRatio,
    sweeps: [(80.0, 250.0), (250.0, 80.0)],
  ),

  /// 中低频：手机、平板的小扬声器在低音区输出很弱时，以其能还原的最低一段
  /// 为准（时宽带宽积 90）
  lowMid(
    offsetUs: 600000,
    durationUs: 200000,
    taperUs: 20000,
    lookbackUs: _lowLookbackUs,
    earliestRatio: _lowEarliestRatio,
    sweeps: [(250.0, 700.0), (700.0, 250.0)],
  );

  const ChirpBand({
    required this.offsetUs,
    required this.durationUs,
    required this.taperUs,
    required this.lookbackUs,
    required this.earliestRatio,
    required this.sweeps,
  });

  /// 低频在室内混响能量常大于直达声，带宽窄、相关峰宽，最强峰常落在直达声
  /// 之后 10~30ms 的混响上；混响只会晚于直达声，向前多找一些、门限放低
  static const _lowLookbackUs = 50000;
  static const _lowEarliestRatio = 0.3;

  /// 在每台设备每轮中相对中高频扫频音的位置
  final int offsetUs;
  final int durationUs;
  final int taperUs;

  /// 直达声：最强峰之前 [lookbackUs] 内，不低于最强峰 [earliestRatio] 倍的最早
  /// 局部峰（较晚的强峰多为反射、混响）
  final int lookbackUs;
  final double earliestRatio;

  /// 各设备的扫频起止频率（Hz），设备多于此数时循环使用（时间上已错开）
  final List<(double, double)> sweeps;

  int get samples => durationUs * CalibrationPlan.sampleRate ~/ 1000000;

  /// 不同的扫频音个数，设备序号按此循环
  int get templates => sweeps.length;
}

/// 测试音：每台设备每个频段一个线性扫频音（频段或方向各不相同），两端平滑
/// 过渡
abstract final class CalibrationSignal {
  static const _amplitude = 0.5;

  /// 检测结果的峰值与背景之比低于此值时视为未检测到
  static const minSnr = 6.0;

  /// 检测到的位置上，本设备模板的相关须至少为附近其他设备模板的此倍数，否则
  /// 多半是窗口内相邻设备的扫频音被误认（合成含噪声与混响的录音中，误认时约
  /// 0.06~0.2，真实检测约 2.2~6.6）
  static const minIdentity = 1.5;

  /// 低频检测到的位置上，本频段模板的相关须高于另一段低频的模板，否则多半是
  /// 另一段的扫频音被误认（合成含混响的录音中，误认时不超过 0.25，真实检测
  /// 不低于 1.6）
  static const minBandIdentity = 1.0;

  /// 设备 [slot] 在 [band] 的扫频音，幅度 -1~1；[quadrature] 时为相位差 90° 的
  /// 同一扫频，两者合起来计算与相位无关的相关
  static Float64List chirp(
    int slot, {
    ChirpBand band = ChirpBand.high,
    bool quadrature = false,
  }) {
    final (f0, f1) = band.sweeps[slot % band.templates];
    const rate = CalibrationPlan.sampleRate;
    final n = band.samples;
    final duration = n / rate;
    final taper = band.taperUs * rate ~/ 1000000;
    final samples = Float64List(n);
    for (var i = 0; i < n; i++) {
      final t = i / rate;
      final phase = 2 * math.pi * (f0 * t + (f1 - f0) * t * t / (2 * duration));
      final edge = math.min(i, n - 1 - i);
      final window = edge >= taper
          ? 1.0
          : 0.5 * (1 - math.cos(math.pi * edge / taper));
      samples[i] = (quadrature ? math.cos(phase) : math.sin(phase)) * window;
    }
    return samples;
  }

  /// 设备 [slot] 按 [plan] 播放的测试音文件（16 位单声道 WAV）
  static Uint8List wav(CalibrationPlan plan, int slot) {
    const rate = CalibrationPlan.sampleRate;
    final total = plan.durationUs * rate ~/ 1000000;
    final chirps = {
      for (final band in ChirpBand.values) band: chirp(slot, band: band),
    };
    final data = ByteData(44 + total * 2);
    void ascii(int offset, String text) {
      for (var i = 0; i < text.length; i++) {
        data.setUint8(offset + i, text.codeUnitAt(i));
      }
    }

    ascii(0, 'RIFF');
    data.setUint32(4, 36 + total * 2, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    data
      ..setUint32(16, 16, Endian.little)
      ..setUint16(20, 1, Endian.little)
      ..setUint16(22, 1, Endian.little)
      ..setUint32(24, rate, Endian.little)
      ..setUint32(28, rate * 2, Endian.little)
      ..setUint16(32, 2, Endian.little)
      ..setUint16(34, 16, Endian.little);
    ascii(36, 'data');
    data.setUint32(40, total * 2, Endian.little);
    void put(Float64List chirp, int atUs) {
      final start = atUs * rate ~/ 1000000;
      for (var i = 0; i < chirp.length && start + i < total; i++) {
        data.setInt16(
          44 + (start + i) * 2,
          (chirp[i] * _amplitude * 32767).round(),
          Endian.little,
        );
      }
    }

    for (var round = 0; round < CalibrationPlan.rounds; round++) {
      for (final MapEntry(key: band, value: chirp) in chirps.entries) {
        put(chirp, plan.chirpAtUs(slot, round, band: band));
      }
    }
    return data.buffer.asUint8List();
  }
}

/// 一次检测：扫频音起点在录音中的位置（采样，含小数）与峰值和背景之比
typedef ChirpDetection = ({double index, double snr});

/// 在录音 [samples] 中寻找设备 [slot] 在 [band] 的扫频音，起点限定在
/// [from, to) 内：与测试音做匹配滤波（频域互相关），取包络峰值；峰值前不远处
/// 另有足够强的峰时取较早者（直达声，见 [ChirpBand.lookbackUs]），再按相邻点
/// 插值到小数采样。背景按最强峰前后一个扫频音长度以外的部分估计，窗口须足够宽
ChirpDetection? detectChirp(
  Int16List samples,
  int slot,
  int from,
  int to, {
  ChirpBand band = ChirpBand.high,
}) {
  final template = CalibrationSignal.chirp(slot, band: band);
  final m = template.length;
  final start = math.max(0, from);
  final end = math.min(samples.length, to + m);
  final lags = end - start - m + 1;
  if (lags <= 2) return null;
  var n = 1;
  while (n < end - start + m) {
    n <<= 1;
  }
  final xr = Float64List(n);
  final xi = Float64List(n);
  for (var i = start; i < end; i++) {
    xr[i - start] = samples[i].toDouble();
  }
  final tr = Float64List(n);
  final ti = Float64List(n);
  tr.setRange(0, m, template);
  _fft(xr, xi);
  _fft(tr, ti);
  // 互相关的频谱，只保留正频率得到解析信号，其模即包络
  final half = n >> 1;
  for (var k = 0; k < n; k++) {
    final scale = k == 0 || k == half ? 1.0 : (k < half ? 2.0 : 0.0);
    final re = xr[k] * tr[k] + xi[k] * ti[k];
    final im = xi[k] * tr[k] - xr[k] * ti[k];
    xr[k] = re * scale;
    xi[k] = im * scale;
  }
  _fft(xr, xi, inverse: true);
  final envelope = Float64List(lags);
  var peak = 0;
  for (var lag = 0; lag < lags; lag++) {
    final value = math.sqrt(xr[lag] * xr[lag] + xi[lag] * xi[lag]);
    envelope[lag] = value;
    if (value > envelope[peak]) peak = lag;
  }
  final maximum = envelope[peak];
  if (maximum <= 0) return null;
  var sum = 0.0;
  var count = 0;
  for (var lag = 0; lag < lags; lag++) {
    if ((lag - peak).abs() < m) continue;
    sum += envelope[lag] * envelope[lag];
    count++;
  }
  final noise = count == 0 ? 0.0 : math.sqrt(sum / count);
  // 直达声：最早的足够强、本身也足以算作检测到的局部峰
  final threshold = math.max(
    maximum * band.earliestRatio,
    noise * CalibrationSignal.minSnr,
  );
  final earliest = math.max(
    1,
    peak - band.lookbackUs * CalibrationPlan.sampleRate ~/ 1000000,
  );
  for (var lag = earliest; lag < peak; lag++) {
    final value = envelope[lag];
    if (value >= threshold &&
        value >= envelope[lag - 1] &&
        value >= envelope[lag + 1]) {
      peak = lag;
      break;
    }
  }
  var fraction = 0.0;
  if (peak > 0 && peak < lags - 1) {
    final a = envelope[peak - 1];
    final b = envelope[peak];
    final c = envelope[peak + 1];
    final denominator = a - 2 * b + c;
    if (denominator != 0) {
      fraction = (0.5 * (a - c) / denominator).clamp(-0.5, 0.5).toDouble();
    }
  }
  return (
    index: start + peak + fraction,
    snr: noise == 0 ? double.infinity : envelope[peak] / noise,
  );
}

/// 录音 [samples] 中自 [index] 起的一段与设备 [slot] 在 [band] 的扫频音的归一化
/// 相关（0~1，与相位无关），在前后 [span] 个采样内取最大
double chirpMatch(
  Int16List samples,
  int slot,
  double index, {
  ChirpBand band = ChirpBand.high,
  int span = 96,
}) {
  final sine = CalibrationSignal.chirp(slot, band: band);
  final cosine = CalibrationSignal.chirp(slot, band: band, quadrature: true);
  final m = sine.length;
  var norm = 0.0;
  for (final value in sine) {
    norm += value * value;
  }
  norm = math.sqrt(norm);
  final center = index.round();
  var best = 0.0;
  for (var lag = center - span; lag <= center + span; lag++) {
    if (lag < 0 || lag + m > samples.length) continue;
    var s = 0.0;
    var c = 0.0;
    var energy = 0.0;
    for (var j = 0; j < m; j++) {
      final x = samples[lag + j].toDouble();
      s += x * sine[j];
      c += x * cosine[j];
      energy += x * x;
    }
    if (energy == 0) continue;
    best = math.max(best, math.sqrt(s * s + c * c) / (math.sqrt(energy) * norm));
  }
  return best;
}

/// 录音中 [index] 处确是设备 [slot]（共 [devices] 台）在 [band] 的扫频音的程度：
/// 本设备模板在该处的相关，与其他设备模板在前后一个扫频音长度内最佳对齐处的
/// 相关中最高者之比（相邻设备的扫频音只与该处部分重叠时也能认出）
double chirpIdentity(
  Int16List samples,
  int slot,
  double index,
  int devices, {
  ChirpBand band = ChirpBand.high,
}) {
  final own = chirpMatch(samples, slot, index, band: band);
  final m = band.samples;
  var other = 0.0;
  for (var candidate = 0; candidate < devices; candidate++) {
    // 循环使用的同一扫频音无法区分，只能靠时间错开
    if (candidate % band.templates == slot % band.templates) {
      continue;
    }
    final found = detectChirp(
      samples,
      candidate,
      (index - m).floor(),
      (index + m).ceil(),
      band: band,
    );
    if (found == null) continue;
    other = math.max(
      other,
      chirpMatch(samples, candidate, found.index, band: band),
    );
  }
  return other == 0 ? double.infinity : own / other;
}

/// 录音中 [index] 处确是设备 [slot] 在低频 [band] 的扫频音、而非其另一段低频
/// 的程度：两段前后相隔 100ms、频率在 250Hz 处相接，一段很弱或没有时其模板
/// 可能与另一段的一端部分对上，误认出差约 130ms 的到达。返回本段模板在该处的
/// 相关，与另一段模板在同该处重叠（超出两端过渡）的位置上最佳相关之比；中高频
/// 与低频不重叠，不核对
double chirpBandIdentity(
  Int16List samples,
  int slot,
  double index, {
  required ChirpBand band,
}) {
  if (band == ChirpBand.high) return double.infinity;
  int samplesOf(int us) => us * CalibrationPlan.sampleRate ~/ 1000000;
  final own = chirpMatch(samples, slot, index, band: band);
  var other = 0.0;
  for (final candidate in const [ChirpBand.bass, ChirpBand.lowMid]) {
    if (candidate == band) continue;
    final found = detectChirp(
      samples,
      slot,
      (index - candidate.samples + samplesOf(candidate.taperUs)).floor(),
      (index + band.samples - samplesOf(band.taperUs)).ceil(),
      band: candidate,
    );
    if (found == null) continue;
    other = math.max(
      other,
      chirpMatch(samples, slot, found.index, band: candidate),
    );
  }
  return other == 0 ? double.infinity : own / other;
}

/// 原位基 2 快速傅里叶变换，长度须为 2 的幂；[inverse] 时含 1/n 归一化
void _fft(Float64List re, Float64List im, {bool inverse = false}) {
  final n = re.length;
  for (var i = 1, j = 0; i < n; i++) {
    var bit = n >> 1;
    for (; j & bit != 0; bit >>= 1) {
      j ^= bit;
    }
    j ^= bit;
    if (i < j) {
      final r = re[i];
      re[i] = re[j];
      re[j] = r;
      final t = im[i];
      im[i] = im[j];
      im[j] = t;
    }
  }
  for (var length = 2; length <= n; length <<= 1) {
    final angle = (inverse ? 2 : -2) * math.pi / length;
    final half = length >> 1;
    for (var k = 0; k < half; k++) {
      final wr = math.cos(angle * k);
      final wi = math.sin(angle * k);
      for (var i = k; i < n; i += length) {
        final b = i + half;
        final r = re[b] * wr - im[b] * wi;
        final t = re[b] * wi + im[b] * wr;
        re[b] = re[i] - r;
        im[b] = im[i] - t;
        re[i] += r;
        im[i] += t;
      }
    }
  }
  if (inverse) {
    for (var i = 0; i < n; i++) {
      re[i] /= n;
      im[i] /= n;
    }
  }
}
