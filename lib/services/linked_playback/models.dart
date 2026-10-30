import 'package:flutter/foundation.dart' show VoidCallback;

enum LinkedRole {
  leader('主控'),
  follower('跟随');

  const LinkedRole(this.label);

  final String label;
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

  /// 跟随端的媒体音量（0~1）
  final double? volume;
}
