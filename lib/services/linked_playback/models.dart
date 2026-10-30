import 'package:flutter/foundation.dart' show VoidCallback;

enum LinkedRole {
  leader('主控'),
  follower('跟随');

  const LinkedRole(this.label);

  final String label;
}

abstract final class LinkedArgs {
  /// 跟随端打开视频页时附带的参数，页面据此自动加载
  static const open = 'linkedPlayback';
}

/// 可联动播放的内容：普通视频的一个分P
class LinkedContent {
  const LinkedContent({
    required this.bvid,
    required this.aid,
    required this.cid,
    this.title,
    this.cover,
  });

  final String bvid;
  final int aid;
  final int cid;
  final String? title;
  final String? cover;

  Map<String, Object?> toJson() => {
    'bvid': bvid,
    'aid': aid,
    'cid': cid,
    'title': title,
    'cover': cover,
  };

  static LinkedContent? fromJson(Object? json) {
    if (json is! Map) return null;
    final bvid = json['bvid'];
    final aid = json['aid'];
    final cid = json['cid'];
    if (bvid is! String || aid is! int || cid is! int) return null;
    final title = json['title'];
    final cover = json['cover'];
    return LinkedContent(
      bvid: bvid,
      aid: aid,
      cid: cid,
      title: title is String ? title : null,
      cover: cover is String ? cover : null,
    );
  }
}

/// 视频页的一次加载由联动播放接管：不自动播放，加载完成后通知联动播放
class LinkedLoad {
  const LinkedLoad({this.position, required VoidCallback onLoaded})
    : _onLoaded = onLoaded;

  /// 加载时直接定位到的位置，为空时按页面原有的起始位置
  final Duration? position;

  final VoidCallback _onLoaded;

  void loaded() => _onLoaded();
}

/// 主控显示的跟随端状态
class LinkedPeerInfo {
  const LinkedPeerInfo({required this.address, this.driftMs, this.rttMs});

  final String address;

  /// 跟随端实测的偏差（已扣除延迟偏移），正值表示跟随端超前
  final double? driftMs;

  final double? rttMs;
}
