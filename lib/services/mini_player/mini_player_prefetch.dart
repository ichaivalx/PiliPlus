import 'package:PiliPlus/common/widgets/pendant_avatar.dart';
import 'package:PiliPlus/grpc/bilibili/main/community/reply/v1.pb.dart'
    show MainListReply, Mode;
import 'package:PiliPlus/grpc/reply.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models/common/video/video_type.dart';
import 'package:PiliPlus/models/model_hot_video_item.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/utils/extension/num_ext.dart';
import 'package:PiliPlus/utils/image_utils.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

/// 小窗播放期间预先获取详情页横屏首屏的相关视频与首页评论，恢复时交给详情页
///
/// 请求对应上游 `RelatedController` 与 `VideoReplyController` 的首次加载，
/// 首屏的判断对应详情页的横屏布局与默认标签，合并上游时需同步检查
class MiniPlayerPrefetch {
  MiniPlayerPrefetch(Map<String, dynamic> args, PlPlayerController player)
    : bvid = args['bvid'] {
    final vertical = player.enableVerticalExpand && args['isVertical'] == true;
    final showComment = Pref.defaultShowComment;
    final showRelated = player.showRelatedVideo;
    // 竖屏视频两侧分别为简介（含相关视频）与评论；其他视频右侧标签页默认为
    // 相关视频，默认显示评论或不显示相关视频时为评论
    showsRelated = showRelated && (vertical || !showComment);
    showsReplies =
        player.showVideoReply && (vertical || showComment || !showRelated);
    if (showsRelated) {
      _fetchRelated();
    }
    if (showsReplies) {
      _fetchReplies(args['aid']);
    }
  }

  final String bvid;

  /// 首屏含相关视频
  late final bool showsRelated;

  /// 首屏含评论
  late final bool showsReplies;

  Success<List<HotVideoItemModel>?>? _related;
  Success<List<HotVideoItemModel>?>? get related => _related;

  Mode? _replyMode;
  Success<MainListReply>? _replies;

  /// 已获取的首页评论，排序需与请求时一致
  Success<MainListReply>? replies(Mode mode) =>
      mode == _replyMode ? _replies : null;

  Future<void> _fetchRelated() async {
    final res = await VideoHttp.relatedVideoList(bvid: bvid);
    if (res case Success(:final response)) {
      _related = Success(response);
      if (response case final list?) {
        _precache((context) {
          final count = (MediaQuery.sizeOf(context).height / 110).ceil();
          return [
            for (final item in list.take(count))
              (src: item.cover, width: 160.0, height: 100.0),
          ];
        });
      }
    }
  }

  /// 排序对应 `ReplyController.onInit`
  Future<void> _fetchReplies(int aid) async {
    final mode = _replyMode = Pref.replySortType == .time
        ? Mode.MAIN_LIST_TIME
        : Mode.MAIN_LIST_HOT;
    final res = await ReplyGrpc.mainList(
      oid: aid,
      type: VideoType.ugc.replyType,
      mode: mode,
      offset: null,
      cursorNext: null,
    );
    if (res case Success(:final response)) {
      _replies = Success(response);
      _precache((context) {
        final count = (MediaQuery.sizeOf(context).height / 80).ceil();
        return [
          for (final reply in [
            if (response.hasUpTop()) response.upTop,
            ...response.replies,
          ].take(count))
            if (PendantAvatar.showDecorate &&
                reply.member.hasGarbPendantImage() &&
                reply.member.garbPendantImage.isNotEmpty)
              (src: reply.member.face, width: 28.0, height: 28.0)
            else
              (src: reply.member.face, width: 34.0, height: 34.0),
        ];
      });
    }
  }

  /// 预先下载并解码首屏图片，恢复时直接命中图片缓存；图片地址与解码尺寸
  /// 对应 `NetworkImgLayer`：相关视频封面 100 高，评论头像 34（带挂件时 28）
  static void _precache(
    List<({String? src, double width, double height})> Function(
      BuildContext context,
    )
    images,
  ) {
    final context = Get.context;
    if (context == null) {
      return;
    }
    for (final (:src, :width, :height) in images(context)) {
      if (src == null || src.isEmpty) {
        continue;
      }
      final url = ImageUtils.thumbnailUrl(src);
      final byWidth = width <= height;
      precacheImage(
        ResizeImage.resizeIfNeeded(
          byWidth ? width.cacheSize(context) : null,
          byWidth ? null : height.cacheSize(context),
          CachedNetworkImageProvider(url, cacheKey: url),
        ),
        context,
        onError: (_, _) {},
      );
    }
  }
}
