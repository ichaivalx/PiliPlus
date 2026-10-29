import 'dart:async' show FutureOr, StreamSubscription, scheduleMicrotask;

import 'package:PiliPlus/common/style.dart';
import 'package:PiliPlus/common/widgets/image/precache.dart';
import 'package:PiliPlus/common/widgets/pendant_avatar.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/member.dart';
import 'package:PiliPlus/models_new/space/space/archive.dart';
import 'package:PiliPlus/models_new/space/space/card.dart';
import 'package:PiliPlus/models_new/space/space/data.dart';
import 'package:PiliPlus/models_new/space/space/images.dart';
import 'package:PiliPlus/models_new/video/video_detail/data.dart';
import 'package:PiliPlus/pages/member/widget/header_layout_widget.dart';
import 'package:PiliPlus/pages/member_opus/widgets/opus_grid.dart';
import 'package:PiliPlus/services/mini_player/mini_player_session.dart';
import 'package:PiliPlus/utils/extension/num_ext.dart';
import 'package:PiliPlus/utils/extension/string_ext.dart';
import 'package:PiliPlus/utils/extension/theme_ext.dart';
import 'package:PiliPlus/utils/grid.dart';
import 'package:PiliPlus/utils/image_utils.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// UP 主空间页数据的预取：视频详情页与小窗（UP 主与合作成员）和 UP 主
/// 面板持有相应的 mid，持有期间始终备好一份，进入空间页时交给
/// `MemberController`，首帧即为实际内容
///
/// 保留未解析的响应，每次取用时各自解析，空间页对数据的修改互不影响；
/// 取用后在后台刷新，刷新完成前仍提供上一份结果；作废时立即丢弃
///
/// 请求参数对应 `MemberController.customGetData`。`from_view_aid` 不影响
/// 空间页读取的字段（与不带时的响应只有图片地址等随机差异），各入口共用
/// 不带它的结果
abstract final class MemberSpacePrefetch {
  /// 持有者及其持有的 mid
  static final Map<Object, Set<int>> _holders = {};
  static final Map<int, _Entry> _entries = {};

  static bool _isHeld(int mid) => _holders.values.any((e) => e.contains(mid));

  /// [owner] 改为持有 [mids]，不再持有的 mid 无人持有时丢弃；同一同步过程
  /// 中转由其他持有者持有时（如小窗恢复为详情页）保留
  static void hold(Object owner, Iterable<Object?> mids) {
    final next = mids.whereType<int>().toSet();
    final prev = _holders.remove(owner) ?? const <int>{};
    if (next.isNotEmpty) {
      _holders[owner] = next;
    }
    final released = prev.difference(next);
    if (released.isNotEmpty) {
      scheduleMicrotask(() {
        for (final mid in released) {
          if (!_isHeld(mid)) {
            _entries.remove(mid);
          }
        }
      });
    }
    for (final mid in next.difference(prev)) {
      if (_entries.putIfAbsent(mid, _Entry.new).data == null) {
        _fetch(mid);
      }
    }
  }

  /// [owner] 改为持有视频 [detail] 的 UP 主与合作成员
  static void holdVideo(Object owner, VideoDetailData? detail) => hold(owner, [
    detail?.owner?.mid,
    ...?detail?.staff?.map((e) => e.mid),
  ]);

  static void release(Object owner) => hold(owner, const []);

  /// 关注关系、资料等变更后，该 mid 已有的结果与进行中的请求不再准确
  static void invalidate(Object? mid) {
    if (_entries[mid] case final entry?) {
      entry
        ..data = null
        ..request = null;
      _fetch(mid as int);
    }
  }

  /// 切换账号后所有结果都不再准确
  static void invalidateAll() => _entries.keys.toList().forEach(invalidate);

  /// 取用 [mid] 的预取：已有结果时同步返回，可直接应用；仍在请求时返回
  /// 同一请求，失败时重新请求；都没有时返回 null，持有中则重新预取
  static FutureOr<LoadingState<SpaceData>>? take(
    int mid,
    Object? fromViewAid,
  ) {
    final entry = _entries[mid];
    if (entry == null) {
      return null;
    }
    if (entry.data case final data?) {
      _fetch(mid);
      return Success(SpaceData.fromJson(data));
    }
    if (entry.request case final request?) {
      return request.then<LoadingState<SpaceData>>(
        (res) async => switch (res) {
          Success(:final response) => Success(SpaceData.fromJson(response)),
          _ => await MemberHttp.space(mid: mid, fromViewAid: fromViewAid),
        },
      );
    }
    _fetch(mid);
    return null;
  }

  /// 在页面转场与小窗展开结束后请求，响应的解析不落在动画中；已在等待或
  /// 请求中时不重复
  static void _fetch(int mid) {
    final entry = _entries[mid];
    if (entry == null || entry.waiting || entry.request != null) {
      return;
    }
    entry.waiting = true;
    _whenSettled(() {
      entry.waiting = false;
      if (!identical(_entries[mid], entry) || entry.request != null) {
        return;
      }
      final request = entry.request = MemberHttp.spaceJson(mid: mid);
      request.then((res) {
        // 已作废
        if (!identical(entry.request, request)) {
          return;
        }
        entry.request = null;
        if (!identical(_entries[mid], entry)) {
          return;
        }
        if (res case Success(:final response)) {
          entry.data = response;
          _precache(response);
        }
      });
    });
  }

  static void _whenSettled(VoidCallback callback) {
    final route = Get.routing.route;
    // ignore: invalid_use_of_protected_member
    final controller = route is TransitionRoute ? route.controller : null;
    if (controller != null && controller.isAnimating) {
      var waiting = true;
      late final AnimationStatusListener onStatus;
      void resume() {
        if (waiting) {
          waiting = false;
          controller.removeStatusListener(onStatus);
          _whenSettled(callback);
        }
      }

      onStatus = (status) {
        if (!status.isAnimating) {
          resume();
        }
      };
      controller.addStatusListener(onStatus);
      // 转场中的页面被移除时控制器随之销毁，不再通知状态
      (route as TransitionRoute).completed.whenComplete(resume);
    } else if (miniPlayerSession.restoring.value) {
      late final StreamSubscription<bool> subscription;
      subscription = miniPlayerSession.restoring.listen((restoring) {
        if (!restoring) {
          subscription.cancel();
          _whenSettled(callback);
        }
      });
    } else {
      callback();
    }
  }

  /// 预先下载并解码空间页首屏的图片，进入时直接命中图片缓存。地址与解码
  /// 尺寸对应 `UserInfoCard` 的头像、挂件与竖屏时的头图，以及
  /// `MemberHome._buildArchive` 中视频分区的封面，合并上游时需同步检查
  static void _precache(Map<String, dynamic> json) {
    final context = Get.context;
    if (context == null) {
      return;
    }
    if (json['card'] case final Map<String, dynamic> card) {
      final SpaceCard(:face, :pendant) = SpaceCard.fromJson(card);
      final pendantImage = pendant?.image;
      final size =
          PendantAvatar.showDecorate && (pendantImage?.isNotEmpty ?? false)
          ? kAvatarSize - 12
          : kAvatarSize;
      precacheNetworkImg(context, face, width: size, height: size);
      precacheNetworkImg(
        context,
        pendantImage,
        width: size * 1.75,
        height: size * 1.75,
      );
    }
    final width = MediaQuery.widthOf(context);
    final isPortrait = width < 600;
    if (json['images'] case final Map<String, dynamic> images when isPortrait) {
      final SpaceImages(:imgUrl, :nightImgurl, :collectionTopSimple) =
          SpaceImages.fromJson(images);
      final imgUrls = collectionTopSimple?.top?.imgUrls;
      final header = imgUrls != null && imgUrls.isNotEmpty
          ? imgUrls.first.header
          : (ColorScheme.of(context).isLight || nightImgurl.isNullOrEmpty
                    ? imgUrl
                    : nightImgurl)
                .http2https;
      precacheNetworkImage(
        context,
        ImageUtils.thumbnailUrl(header),
        cacheWidth: width.cacheSize(context),
      );
    }
    if (json['archive'] case final Map<String, dynamic> archive) {
      final padding = MediaQuery.viewPaddingOf(context);
      final grid =
          OpusGridDelegate(
            crossAxisSpacing: Style.cardSpace,
            maxCrossAxisExtent: Grid.smallCardWidth,
            childAspectRatio: Style.aspectRatio,
          ).calcCrossAxisCount(
            BoxConstraints(
              maxWidth: width - padding.horizontal - 2 * Style.safeSpace,
            ),
          );
      final coverWidth = grid.childCrossAxisExtent;
      final count = isPortrait ? grid.crossAxisCount * 2 : grid.crossAxisCount;
      for (final item
          in Archive.fromJson(archive).item?.take(count) ?? const []) {
        precacheNetworkImg(
          context,
          item.cover,
          width: coverWidth,
          height: coverWidth / Style.aspectRatio,
        );
      }
    }
  }
}

class _Entry {
  /// 最近一次成功的响应，后台刷新期间仍可取用
  Map<String, dynamic>? data;

  /// 进行中的请求
  Future<LoadingState<Map<String, dynamic>>>? request;

  /// 已安排请求，等待转场结束
  bool waiting = false;
}
