import 'package:PiliPlus/services/linked_playback/calibration_signal.dart';
import 'package:PiliPlus/services/linked_playback/leader.dart';
import 'package:PiliPlus/services/linked_playback/linked_playback.dart'
    show LinkedPlayback;
import 'package:PiliPlus/utils/storage.dart';
import 'package:get/get.dart';

final linkedBand = LinkedBand._();

/// 各低频频段实测的低频相对中高频额外的延迟（微秒），只含能可靠测出的频段
typedef BandGaps = Map<ChirpBand, int>;

/// 两台设备都可靠测得的低频频段，优先低音区；没有共同频段时为空
ChirpBand? commonBand(BandGaps a, BandGaps b) {
  for (final band in const [ChirpBand.bass, ChirpBand.lowMid]) {
    if (a.containsKey(band) && b.containsKey(band)) return band;
  }
  return null;
}

/// 主控的按频段对齐：校准实测各设备各低频频段相对中高频额外的延迟，跟随端与
/// 主控按两者都测得的同一频段比较（优先低音区），得到差值 Δg（没有共同频段时
/// 保底按 0 计）；位置 w 在按中高频对齐（0）与按低频对齐（1）之间连续调节，各
/// 跟随端的延迟偏移在中高频对齐的基础上平移 −w·Δg。平移量记在主控，滑块移动、
/// 重新校准或跟随端重新连接时按差额改写其偏移；手动调节的偏移与平移叠加，互不
/// 影响
class LinkedBand {
  LinkedBand._();

  static const _weightKey = 'linkedPlaybackBandWeight';
  static const _leaderGapsKey = 'linkedPlaybackBandLeaderGaps';
  static const _peerGapsKey = 'linkedPlaybackBandPeerGaps';
  static const _appliedKey = 'linkedPlaybackBandApplied';

  /// 0 为按中高频对齐，1 为按低频对齐
  final RxDouble weight = RxDouble(
    (GStorage.setting.get(_weightKey, defaultValue: 0.0) as num).toDouble(),
  );

  /// 主控各频段实测的低频额外延迟
  final Rx<BandGaps> leaderGaps = Rx<BandGaps>(
    _gapsOf(GStorage.setting.get(_leaderGapsKey)),
  );

  /// 各跟随端（设备标识）各频段实测的低频额外延迟；都测不出或未校准过的没有
  /// 记录
  final RxMap<String, BandGaps> gaps = RxMap<String, BandGaps>(_loadPeers());

  /// 各跟随端的延迟偏移中已含的平移量（微秒，按偏移的调节单位取整）
  final Map<String, int> _applied = _loadApplied();

  /// 已发出、尚待跟随端回报确认的偏移改写及其中所含的平移量
  final Map<String, ({int offsetUs, int shift})> _pending = {};

  static BandGaps _gapsOf(Object? stored) {
    if (stored is! Map) return {};
    final bands = ChirpBand.values.asNameMap();
    return {
      for (final MapEntry(key: name, value: gap) in stored.entries)
        if (bands[name] case final band? when gap is int) band: gap,
    };
  }

  static Map<String, Object> _gapsToJson(BandGaps gaps) => {
    for (final MapEntry(key: band, value: gap) in gaps.entries) band.name: gap,
  };

  static Map<String, BandGaps> _loadPeers() {
    final stored = GStorage.setting.get(_peerGapsKey);
    if (stored is! Map) return {};
    return {
      for (final MapEntry(key: id, value: value) in stored.entries)
        if (id is String) id: _gapsOf(value),
    };
  }

  static Map<String, int> _loadApplied() {
    final stored = GStorage.setting.get(_appliedKey);
    if (stored is! Map) return {};
    return {
      for (final MapEntry(key: id, value: shift) in stored.entries)
        if (id is String && shift is int) id: shift,
    };
  }

  /// 有低频的实测数据，滑块可用
  bool get available => leaderGaps.value.isNotEmpty || gaps.isNotEmpty;

  /// 跟随端 [id] 与主控比较所用的共同频段及两者的实测值，没有共同频段时为空
  ({ChirpBand band, int gap, int leaderGap})? pairFor(String id) {
    final BandGaps peer = gaps[id] ?? const {};
    final leader = leaderGaps.value;
    final band = commonBand(peer, leader);
    if (band == null) return null;
    return (band: band, gap: peer[band]!, leaderGap: leader[band]!);
  }

  /// 跟随端 [id] 在当前位置应有的平移量
  int shiftFor(String id) {
    final pair = pairFor(id);
    if (pair == null) return 0;
    const step = LinkedPlayback.offsetStepUs;
    final shift = -weight.value * (pair.gap - pair.leaderGap);
    return (shift / step).round() * step;
  }

  void _setApplied(String id, int value) {
    if (_applied[id] == value) return;
    _applied[id] = value;
    GStorage.setting.put(_appliedKey, Map<String, int>.of(_applied));
  }

  /// 改写跟随端 [id] 的偏移为 [offsetUs]，其中含平移量 [shift]；跟随端回报
  /// 相同的偏移后才记为已平移
  void setOffset(LeaderSession leader, String id, int offsetUs, int shift) {
    _pending[id] = (offsetUs: offsetUs, shift: shift);
    leader.setOffset(id, offsetUs);
  }

  /// 主控手动改写跟随端 [id] 的偏移：手动值基于当前（含待确认的平移）的偏移，
  /// 待确认的改写改以手动值为准，其中的平移量不变
  void setManualOffset(LeaderSession leader, String id, int offsetUs) {
    if (_pending[id] case final pending?) {
      _pending[id] = (offsetUs: offsetUs, shift: pending.shift);
    }
    leader.setOffset(id, offsetUs);
  }

  /// 在线跟随端的偏移按当前位置补齐平移量（滑块移动、跟随端回报后）。改写
  /// 尚无回报时不动；等待超时后回报的是其他值（未送达，或期间在跟随端手动
  /// 调节过）时视为未平移，在其回报的偏移上重新补齐
  void apply(LeaderSession leader) {
    for (final peer in leader.calibrationPeers) {
      if (!peer.settled) continue;
      if (_pending.remove(peer.id) case final pending?
          when pending.offsetUs == peer.offsetUs) {
        _setApplied(peer.id, pending.shift);
      }
      final target = shiftFor(peer.id);
      final applied = _applied[peer.id] ?? 0;
      if (target == applied) continue;
      setOffset(leader, peer.id, peer.offsetUs + target - applied, target);
    }
  }

  void setWeight(double value, LeaderSession? leader) {
    weight.value = value.clamp(0.0, 1.0).toDouble();
    GStorage.setting.put(_weightKey, weight.value);
    if (leader != null) apply(leader);
  }

  /// 校准测得主控与跟随端 [peers]（设备标识）各频段的低频额外延迟，为空的
  /// 未能实测
  void calibrated(BandGaps leader, Map<String, BandGaps> peers) {
    leaderGaps.value = Map.of(leader);
    for (final MapEntry(key: id, value: value) in peers.entries) {
      if (value.isEmpty) {
        gaps.remove(id);
      } else {
        gaps[id] = Map.of(value);
      }
    }
    _saveGaps();
  }

  void _saveGaps() {
    GStorage.setting
      ..put(_leaderGapsKey, _gapsToJson(leaderGaps.value))
      ..put(_peerGapsKey, {
        for (final MapEntry(key: id, value: value) in gaps.entries)
          id: _gapsToJson(value),
      });
  }

  /// 当前的低频记录，及各跟随端当前偏移（含尚待确认的改写）中的平移量
  LinkedBandState snapshot() => (
    leaderGaps: Map.of(leaderGaps.value),
    gaps: {
      for (final MapEntry(key: id, value: value) in gaps.entries)
        id: Map.of(value),
    },
    applied: {
      ..._applied,
      for (final MapEntry(key: id, value: pending) in _pending.entries)
        id: pending.shift,
    },
  );

  /// 恢复低频记录（撤销校准）；平移量随各跟随端偏移的改写确认后更新
  void restore(LinkedBandState state) {
    leaderGaps.value = state.leaderGaps;
    gaps.assignAll(state.gaps);
    _saveGaps();
  }
}

typedef LinkedBandState = ({
  BandGaps leaderGaps,
  Map<String, BandGaps> gaps,
  Map<String, int> applied,
});
