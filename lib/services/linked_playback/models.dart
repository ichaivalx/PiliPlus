import 'package:flutter/foundation.dart' show VoidCallback;

enum LinkedRole {
  leader('主控'),
  follower('跟随');

  const LinkedRole(this.label);

  final String label;
}

/// 主控播放中拖动进度时的同步方式
enum LinkedSeekMode {
  together('两端一起对齐', '主控拖动后两端一起暂停、定位，再同时开始播放；主控会短暂停顿'),
  catchUp('主控不停，跟随端追上', '主控照常播放，跟随端立即定位并在缓冲后跳转追上；跟随端会短暂静音');

  const LinkedSeekMode(this.label, this.description);

  final String label;
  final String description;
}

/// 播放内容所在的页面
enum LinkedKind {
  /// 视频详情页
  video,

  /// 听视频页
  audio,
}

abstract final class LinkedArgs {
  /// 跟随端打开页面时附带的参数，页面据此自动加载且不续播上次进度
  static const open = 'linkedPlayback';
}

/// 可联动播放的内容：普通视频的一个分P
class LinkedContent {
  const LinkedContent({
    required this.kind,
    required this.bvid,
    required this.aid,
    required this.cid,
    this.title,
    this.cover,
  });

  final LinkedKind kind;
  final String bvid;
  final int aid;
  final int cid;
  final String? title;
  final String? cover;

  bool isSame(LinkedContent? other) =>
      other != null && other.kind == kind && other.cid == cid;

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'bvid': bvid,
    'aid': aid,
    'cid': cid,
    'title': title,
    'cover': cover,
  };

  static LinkedContent? fromJson(Object? json) {
    if (json is! Map) return null;
    final kind = LinkedKind.values.asNameMap()[json['kind']];
    final bvid = json['bvid'];
    final aid = json['aid'];
    final cid = json['cid'];
    if (kind == null || bvid is! String || aid is! int || cid is! int) {
      return null;
    }
    final title = json['title'];
    final cover = json['cover'];
    return LinkedContent(
      kind: kind,
      bvid: bvid,
      aid: aid,
      cid: cid,
      title: title is String ? title : null,
      cover: cover is String ? cover : null,
    );
  }
}

/// 跟随端系统媒体音量的控制方式
enum LinkedVolumeMode {
  follow('跟随主控'),
  independent('独立');

  const LinkedVolumeMode(this.label);

  final String label;
}

/// 跟随端的音量设置与当前实际音量，由跟随端保存
class LinkedVolume {
  const LinkedVolume({
    required this.mode,
    required this.offset,
    required this.level,
    this.actual,
  });

  final LinkedVolumeMode mode;

  /// 跟随主控时相对主控音量的偏移（百分点）
  final int offset;

  /// 独立时设定的音量（0~1）
  final double level;

  /// 跟随端当前的系统媒体音量（0~1）
  final double? actual;

  /// 跟随主控时应设定的音量
  double? targetFor(double? leaderVolume) => switch (mode) {
    LinkedVolumeMode.follow =>
      leaderVolume == null
          ? null
          : (leaderVolume + offset / 100).clamp(0.0, 1.0).toDouble(),
    LinkedVolumeMode.independent => level,
  };

  /// 切换模式，保持跟随端当前的音量不变
  LinkedVolume switchTo(LinkedVolumeMode value, double? leaderVolume) {
    final current = actual;
    return switch (value) {
      LinkedVolumeMode.follow => LinkedVolume(
        mode: value,
        offset: current == null || leaderVolume == null
            ? offset
            : ((current - leaderVolume) * 100).round(),
        level: level,
        actual: actual,
      ),
      LinkedVolumeMode.independent => LinkedVolume(
        mode: value,
        offset: offset,
        level: current ?? level,
        actual: actual,
      ),
    };
  }

  LinkedVolume copyWith({
    LinkedVolumeMode? mode,
    int? offset,
    double? level,
    double? actual,
  }) => LinkedVolume(
    mode: mode ?? this.mode,
    offset: offset ?? this.offset,
    level: level ?? this.level,
    actual: actual ?? this.actual,
  );

  Map<String, Object?> toJson() => {
    'mode': mode.name,
    'offset': offset,
    'level': level,
    'actual': ?actual,
  };

  static LinkedVolume? fromJson(Object? json) {
    if (json is! Map) return null;
    final mode = LinkedVolumeMode.values.asNameMap()[json['mode']];
    final offset = json['offset'];
    final level = json['level'];
    final actual = json['actual'];
    if (mode == null || offset is! int || level is! num) return null;
    return LinkedVolume(
      mode: mode,
      offset: offset,
      level: level.toDouble(),
      actual: actual is num ? actual.toDouble() : null,
    );
  }
}

/// 页面的一次加载由联动播放接管：不自动播放，加载完成后通知联动播放
class LinkedLoad {
  const LinkedLoad({this.position, required VoidCallback onLoaded})
    : _onLoaded = onLoaded;

  /// 加载时直接定位到的位置，为空时按页面原有的起始位置
  final Duration? position;

  final VoidCallback _onLoaded;

  void loaded() => _onLoaded();
}

/// 跟随端的状态
enum LinkedPeerState {
  idle('已连接'),
  preparing('准备中'),
  buffering('缓冲中'),
  playing('同步播放中'),
  paused('已暂停'),
  localPaused('被本机暂停'),
  failed('播放失败'),
  offline('离线');

  const LinkedPeerState(this.label);

  final String label;
}

/// 主控显示的跟随端
class LinkedPeerInfo {
  const LinkedPeerInfo({
    required this.id,
    required this.name,
    required this.address,
    required this.state,
    this.reason,
    this.driftMs,
    this.rttMs,
    this.volume,
    this.offsetUs,
  });

  final String id;
  final String name;
  final String address;
  final LinkedPeerState state;

  /// 播放失败的原因
  final String? reason;

  /// 跟随端实测的偏差（已扣除延迟偏移），正值表示跟随端超前
  final double? driftMs;

  final double? rttMs;

  /// 跟随端的音量设置与当前音量
  final LinkedVolume? volume;

  /// 跟随端的延迟偏移（微秒）
  final int? offsetUs;
}
