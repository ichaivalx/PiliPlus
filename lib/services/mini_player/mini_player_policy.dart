import 'package:PiliPlus/models/common/video/source_type.dart';
import 'package:PiliPlus/models/common/video/video_type.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:flutter/widgets.dart';

enum MiniRouteKind {
  /// 弹窗、半透明页面等，视频保持原位播放
  overlay,

  /// 视频详情页
  video,

  /// 独占播放器的页面
  exclusive,

  /// 普通内容页
  content,
}

/// 缩小、恢复时小窗、页面淡入淡出共用的动画参数
abstract final class MiniPlayerMotion {
  static const duration = Duration(milliseconds: 300);
  static const curve = Curves.fastOutSlowIn;
}

abstract final class MiniPlayerPolicy {
  static const videoRoute = '/videoV';

  static const _exclusiveRoutes = {
    '/liveRoom',
    '/audio',
    '/videoWeb',
    '/ssWeb',
    '/dlna',
  };

  static String? _routeName(Route<dynamic> route) =>
      route.settings.name?.split('?').first;

  static MiniRouteKind classify(Route<dynamic> route) {
    if (route is! PageRoute || !route.opaque) {
      return .overlay;
    }
    final name = _routeName(route);
    if (name == videoRoute) {
      return .video;
    }
    if (_exclusiveRoutes.contains(name)) {
      return .exclusive;
    }
    return .content;
  }

  static bool isTabletLandscape(Size size) =>
      PlatformUtils.isMobile &&
      size.width > size.height &&
      size.shortestSide >= 600;

  /// 可在小窗内直接加载的视频参数
  static bool canLoadInMini(Map args) =>
      args['videoType'] == VideoType.ugc &&
      args['pgcApi'] != true &&
      args['pgcItem'] == null &&
      args['sourceType'] != SourceType.file;
}
