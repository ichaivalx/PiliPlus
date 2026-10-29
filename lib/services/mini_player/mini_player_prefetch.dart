import 'package:PiliPlus/common/widgets/image/precache.dart';
import 'package:PiliPlus/common/widgets/pendant_avatar.dart';
import 'package:PiliPlus/grpc/bilibili/main/community/reply/v1.pb.dart'
    show MainListReply, Mode;
import 'package:PiliPlus/grpc/reply.dart';
import 'package:PiliPlus/http/api.dart';
import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/member.dart';
import 'package:PiliPlus/http/user.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models/common/video/video_type.dart';
import 'package:PiliPlus/models/model_hot_video_item.dart';
import 'package:PiliPlus/models_new/member_card_info/data.dart';
import 'package:PiliPlus/models_new/relation/data.dart';
import 'package:PiliPlus/models_new/video/video_detail/data.dart';
import 'package:PiliPlus/models_new/video/video_detail/staff.dart';
import 'package:PiliPlus/models_new/video/video_relation/data.dart';
import 'package:PiliPlus/models_new/video/video_tag/data.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

/// 小窗播放期间预先获取详情页首屏可能显示的内容：相关视频、首页评论，以及
/// 简介中的标签、UP 主信息与当前账号的点赞、投币、收藏、关注状态，恢复时
/// 交给详情页。恢复时的布局显示其中哪些由页面按当时的尺寸决定，这里按设置
/// 获取全部
///
/// 请求对应上游 `RelatedController`、`VideoReplyController` 的首次加载与
/// `CommonIntroController.queryVideoTags`、`UgcIntroController` 的
/// `queryUserStat`、`queryAllStatus`、`queryFollowStatus`，合并上游时需同步检查
class MiniPlayerPrefetch {
  MiniPlayerPrefetch(Map<String, dynamic> args, PlPlayerController player)
    : bvid = args['bvid'],
      cid = args['cid'] {
    _fetchTags();
    if (_isLogin) {
      _fetchRelation();
    }
    if (player.showRelatedVideo) {
      _fetchRelated();
    }
    if (player.showVideoReply) {
      _fetchReplies(args['aid']);
    }
  }

  final String bvid;
  final int? cid;

  /// 对应 `CommonIntroController.isLogin`：未登录时详情页不查询这些状态
  static bool get _isLogin => Accounts.main.isLogin;

  /// 关系变更或切换账号时递增，此前发出的请求结果不再采用
  int _relationEpoch = 0;
  int _memberEpoch = 0;

  Success<VideoRelation>? _relation;

  /// 已获取的点赞、点踩、投币、收藏状态
  Success<VideoRelation>? get relation => _relation;

  Success<List<HotVideoItemModel>?>? _related;
  Success<List<HotVideoItemModel>?>? get related => _related;

  Mode? _replyMode;
  Success<MainListReply>? _replies;

  /// 已获取的首页评论，排序需与请求时一致
  Success<MainListReply>? replies(Mode mode) =>
      mode == _replyMode ? _replies : null;

  Success<List<VideoTagItem>?>? _tags;

  /// 已获取的标签，需与请求的视频分P一致
  Success<List<VideoTagItem>?>? tags(String bvid, int cid) =>
      bvid == this.bvid && cid == this.cid ? _tags : null;

  int? _ownerMid;
  List<Staff>? _staff;
  Success<MemberCardInfoData>? _owner;
  Success<RelationData>? _follow;

  /// 已获取的 UP 主信息，需与详情中的 UP 主一致
  Success<MemberCardInfoData>? owner(int mid) =>
      mid == _ownerMid ? _owner : null;

  /// 已获取的 UP 主关注状态，需与详情中的 UP 主一致
  Success<RelationData>? follow(int mid) => mid == _ownerMid ? _follow : null;

  Map<String, dynamic>? _staffRelations;

  /// 已获取的合作成员关注状态（原始响应）
  Map<String, dynamic>? get staffRelations => _staffRelations;

  /// 视频详情到达后获取 UP 主信息与关注状态；合作视频的成员在详情中，
  /// 只获取其关注状态
  void ownerOf(VideoDetailData detail) {
    final mid = detail.owner?.mid;
    if (_ownerMid != null || detail.bvid != bvid || mid == null) {
      return;
    }
    _ownerMid = mid;
    if (detail.staff case final staff? when staff.isNotEmpty) {
      _staff = staff;
    }
    _fetchMember();
  }

  void _fetchMember() {
    final mid = _ownerMid!;
    if (_staff case final staff?) {
      _fetchStaffRelations(staff);
      return;
    }
    _fetchOwner(mid);
    if (_isLogin) {
      _fetchFollow(mid);
    }
  }

  /// [mid] 的关注关系、资料等变更后，丢弃已获取的 UP 主或合作成员的结果
  /// 并重新获取，进行中的请求结果不再采用
  void invalidateMember(Object? mid) {
    if (_ownerMid == null ||
        (mid != _ownerMid && !(_staff?.any((e) => e.mid == mid) ?? false))) {
      return;
    }
    _discardMember();
    _fetchMember();
  }

  /// 切换账号后丢弃与账号相关的结果并重新获取
  void invalidateAccount() {
    _relationEpoch++;
    _relation = null;
    if (_isLogin) {
      _fetchRelation();
    }
    if (_ownerMid != null) {
      _discardMember();
      _fetchMember();
    }
  }

  void _discardMember() {
    _memberEpoch++;
    _owner = null;
    _follow = null;
    _staffRelations = null;
  }

  Future<void> _fetchRelation() async {
    final epoch = _relationEpoch;
    final res = await VideoHttp.videoRelation(bvid: bvid);
    if (epoch != _relationEpoch) {
      return;
    }
    if (res case Success(:final response)) {
      _relation = Success(response);
    }
  }

  Future<void> _fetchFollow(int mid) async {
    final epoch = _memberEpoch;
    final res = await UserHttp.userRelation(mid);
    if (epoch != _memberEpoch) {
      return;
    }
    if (res case Success(:final response)) {
      _follow = Success(response);
    }
  }

  /// 对应 `UgcIntroController.queryUserStat` 中合作成员的请求
  Future<void> _fetchStaffRelations(List<Staff> staff) async {
    final epoch = _memberEpoch;
    final res = await Request().get(
      Api.relations,
      queryParameters: {'fids': staff.map((item) => item.mid).join(',')},
    );
    if (epoch != _memberEpoch) {
      return;
    }
    if (res.data case final Map<String, dynamic> data
        when data['code'] == 0) {
      _staffRelations = data;
    }
  }

  Future<void> _fetchOwner(int mid) async {
    final epoch = _memberEpoch;
    final res = await MemberHttp.memberCardInfo(mid: mid);
    if (epoch != _memberEpoch) {
      return;
    }
    if (res case Success(:final response)) {
      _owner = Success(response);
      _precache(
        (_) => [(src: response.card?.face, width: 35.0, height: 35.0)],
      );
    }
  }

  Future<void> _fetchTags() async {
    final res = await UserHttp.videoTags(bvid: bvid, cid: cid);
    if (res case Success(:final response)) {
      _tags = Success(response);
    }
  }

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
  /// 对应 `NetworkImgLayer`：相关视频封面 100 高，评论头像 34（带挂件时 28），
  /// UP 主头像 35
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
      precacheNetworkImg(context, src, width: width, height: height);
    }
  }
}
