import 'dart:math' as math;
import 'dart:typed_data';

/// 一次声学校准的安排，各端共用：所有设备在约定时刻 [startAt]（主控时钟，
/// 微秒）同时开始播放各自的测试音文件，设备 [slot] 第 r 轮的扫频音位于文件中
/// [chirpAtUs] 处；各设备、各轮依次间隔 [spacingUs]，互不重叠
class CalibrationPlan {
  const CalibrationPlan({
    required this.id,
    required this.devices,
    required this.startAt,
  });

  static const rounds = 3;
  static const sampleRate = 48000;
  static const spacingUs = 500000;

  /// 文件开头的静音，等待音频输出启动稳定
  static const leadUs = 400000;

  final int id;

  /// 参与的设备数，主控为第 0 台
  final int devices;
  final int startAt;

  int chirpAtUs(int slot, int round) =>
      leadUs + slot * spacingUs + round * devices * spacingUs;

  int get durationUs => leadUs + rounds * devices * spacingUs;

  Map<String, Object?> toJson() => {
    'id': id,
    'devices': devices,
    'start': startAt,
  };

  static CalibrationPlan? fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final devices = json['devices'];
    final start = json['start'];
    if (id is! int || devices is! int || start is! int || devices < 1) {
      return null;
    }
    return CalibrationPlan(id: id, devices: devices, startAt: start);
  }
}

/// 测试音：每台设备一个不同的线性扫频音（频段或方向不同），两端平滑过渡
abstract final class CalibrationSignal {
  static const chirpUs = 80000;
  static const _taperUs = 5000;
  static const _amplitude = 0.5;

  /// 各设备的扫频起止频率（Hz），设备多于此数时循环使用（时间上已错开）
  static const _bands = [
    (1500.0, 4500.0),
    (4500.0, 1500.0),
    (2000.0, 6000.0),
    (6000.0, 2000.0),
    (1200.0, 3600.0),
    (3600.0, 1200.0),
  ];

  /// 检测结果的峰值与背景之比低于此值时视为未检测到
  static const minSnr = 6.0;

  static int get chirpSamples =>
      chirpUs * CalibrationPlan.sampleRate ~/ 1000000;

  /// 设备 [slot] 的扫频音，幅度 -1~1
  static Float64List chirp(int slot) {
    final (f0, f1) = _bands[slot % _bands.length];
    const rate = CalibrationPlan.sampleRate;
    final n = chirpSamples;
    final duration = n / rate;
    final taper = _taperUs * rate ~/ 1000000;
    final samples = Float64List(n);
    for (var i = 0; i < n; i++) {
      final t = i / rate;
      final phase = 2 * math.pi * (f0 * t + (f1 - f0) * t * t / (2 * duration));
      final edge = math.min(i, n - 1 - i);
      final window = edge >= taper
          ? 1.0
          : 0.5 * (1 - math.cos(math.pi * edge / taper));
      samples[i] = math.sin(phase) * window;
    }
    return samples;
  }

  /// 设备 [slot] 按 [plan] 播放的测试音文件（16 位单声道 WAV）
  static Uint8List wav(CalibrationPlan plan, int slot) {
    const rate = CalibrationPlan.sampleRate;
    final total = plan.durationUs * rate ~/ 1000000;
    final chirp = CalibrationSignal.chirp(slot);
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
    for (var round = 0; round < CalibrationPlan.rounds; round++) {
      final start = plan.chirpAtUs(slot, round) * rate ~/ 1000000;
      for (var i = 0; i < chirp.length && start + i < total; i++) {
        data.setInt16(
          44 + (start + i) * 2,
          (chirp[i] * _amplitude * 32767).round(),
          Endian.little,
        );
      }
    }
    return data.buffer.asUint8List();
  }
}

/// 一次检测：扫频音起点在录音中的位置（采样，含小数）与峰值和背景之比
typedef ChirpDetection = ({double index, double snr});

/// 在录音 [samples] 中寻找设备 [slot] 的扫频音，起点限定在 [from, to) 内：
/// 与测试音做匹配滤波（频域互相关），取包络峰值；峰值前不远处另有足够强的
/// 峰时取较早者（直达声，较晚的强峰多为反射），再按相邻点插值到小数采样
ChirpDetection? detectChirp(Int16List samples, int slot, int from, int to) {
  final template = CalibrationSignal.chirp(slot);
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
  // 直达声：峰值前 15ms 内不低于峰值一半的最早局部峰
  final earliest = math.max(1, peak - 15 * CalibrationPlan.sampleRate ~/ 1000);
  for (var lag = earliest; lag < peak; lag++) {
    final value = envelope[lag];
    if (value >= maximum * 0.5 &&
        value >= envelope[lag - 1] &&
        value >= envelope[lag + 1]) {
      peak = lag;
      break;
    }
  }
  var sum = 0.0;
  var count = 0;
  for (var lag = 0; lag < lags; lag++) {
    if ((lag - peak).abs() < m) continue;
    sum += envelope[lag] * envelope[lag];
    count++;
  }
  final noise = count == 0 ? 0.0 : math.sqrt(sum / count);
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
