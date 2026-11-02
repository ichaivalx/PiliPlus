import 'package:PiliPlus/services/linked_playback/leader.dart';
import 'package:PiliPlus/services/linked_playback/linked_playback.dart'
    show LinkedPlayback;
import 'package:PiliPlus/utils/storage.dart';
import 'package:get/get.dart';

final linkedBand = LinkedBand._();

/// 主控的按频段对齐：校准实测各设备低频相对中高频额外的延迟 g（主控为 g₀，
/// 测不出的设备保底按 0 计），位置 w 在按中高频对齐（0）与按低频对齐（1）之间
/// 连续调节，各跟随端的延迟偏移在中高频对齐的基础上平移 −w·(g − g₀)，使各设备
/// 的等效到达 H + w·g 一致。平移量记在主控，滑块移动、重新校准或跟随端重新
/// 连接时按差额改写其偏移；手动调节的偏移与平移叠加，互不影响
class LinkedBand {
  LinkedBand._();

  static const _weightKey = 'linkedPlaybackBandWeight';
  static const _leaderGapKey = 'linkedPlaybackBandLeaderGap';
  static const _gapsKey = 'linkedPlaybackBandGaps';
  static const _appliedKey = 'linkedPlaybackBandApplied';

  /// 0 为按中高频对齐，1 为按低频对齐
  final RxDouble weight = RxDouble(
    (GStorage.setting.get(_weightKey, defaultValue: 0.0) as num).toDouble(),
  );

  /// 主控实测的低频相对中高频额外的延迟（微秒），测不出时为空，按 0 计
  final RxnInt leaderGap = RxnInt(GStorage.setting.get(_leaderGapKey) as int?);

  /// 各跟随端（设备标识）实测的低频相对中高频额外的延迟（微秒）；测不出或
  /// 未校准过的没有记录，按 0 计
  final RxMap<String, int> gaps = RxMap<String, int>(_load(_gapsKey));

  /// 各跟随端的延迟偏移中已含的平移量（微秒，按偏移的调节单位取整）
  final Map<String, int> _applied = _load(_appliedKey);

  /// 已发出、尚待跟随端回报确认的偏移改写及其中所含的平移量
  final Map<String, ({int offsetUs, int shift})> _pending = {};

  static Map<String, int> _load(String key) {
    final stored = GStorage.setting.get(key);
    if (stored is! Map) return {};
    return {
      for (final MapEntry(key: id, value: gap) in stored.entries)
        if (id is String && gap is int) id: gap,
    };
  }

  /// 有低频的实测数据，滑块可用
  bool get available => leaderGap.value != null || gaps.isNotEmpty;

  /// 跟随端 [id] 在当前位置应有的平移量
  int shiftFor(String id) {
    const step = LinkedPlayback.offsetStepUs;
    final shift = -weight.value * ((gaps[id] ?? 0) - (leaderGap.value ?? 0));
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

  /// 校准测得主控与跟随端 [peers]（设备标识）的低频额外延迟，为空的未能实测
  void calibrated(int? leader, Map<String, int?> peers) {
    leaderGap.value = leader;
    for (final MapEntry(key: id, value: gap) in peers.entries) {
      if (gap == null) {
        gaps.remove(id);
      } else {
        gaps[id] = gap;
      }
    }
    _saveGaps();
  }

  void _saveGaps() {
    if (leaderGap.value case final gap?) {
      GStorage.setting.put(_leaderGapKey, gap);
    } else {
      GStorage.setting.delete(_leaderGapKey);
    }
    GStorage.setting.put(_gapsKey, Map<String, int>.of(gaps));
  }

  /// 当前的低频记录，及各跟随端当前偏移（含尚待确认的改写）中的平移量
  LinkedBandState snapshot() => (
    leaderGap: leaderGap.value,
    gaps: Map.of(gaps),
    applied: {
      ..._applied,
      for (final MapEntry(key: id, value: pending) in _pending.entries)
        id: pending.shift,
    },
  );

  /// 恢复低频记录（撤销校准）；平移量随各跟随端偏移的改写确认后更新
  void restore(LinkedBandState state) {
    leaderGap.value = state.leaderGap;
    gaps.assignAll(state.gaps);
    _saveGaps();
  }
}

typedef LinkedBandState = ({
  int? leaderGap,
  Map<String, int> gaps,
  Map<String, int> applied,
});
