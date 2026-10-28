import 'package:PiliPlus/models/video/play/url.dart';
import 'package:PiliPlus/pages/common/common_intro_controller.dart';
import 'package:PiliPlus/pages/video/controller.dart';
import 'package:PiliPlus/pages/video/view.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/services/mini_player/mini_player_policy.dart';
import 'package:PiliPlus/services/mini_player/mini_player_queue.dart';
import 'package:PiliPlus/services/mini_player/mini_player_session.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

mixin MiniPlayerHostMixin on State<VideoDetailPageV>, RouteAware
    implements MiniPlayerHost {
  VideoDetailController get videoDetailController;
  CommonIntroController get introController;
  PlPlayerController? get plPlayerController;
  bool get isShowing;
  Future<void> playerListener(PlayerStatus status);
  void positionListener(Duration position);

  @override
  late final Route<dynamic>? miniRoute;

  @override
  String get miniHeroTag => videoDetailController.heroTag;

  bool get isCoveredByMiniPlayer => miniPlayerSession.covers(this);

  void initMiniPlayerHost() {
    miniRoute = Get.routing.route;
    miniPlayerSession.attach(this);
    if (miniPlayerSession.isRestoreTarget(miniHeroTag)) {
      videoDetailController.autoPlay = true;
      _reportRestoreRect();
    }
  }

  void disposeMiniPlayerHost() => miniPlayerSession.detach(this);

  void _reportRestoreRect() {
    void report() {
      if (mounted) {
        miniPlayerSession.reportRestoreRect(this);
      }
    }

    final animation = (miniRoute as ModalRoute?)?.animation;
    if (animation == null || animation.isCompleted) {
      WidgetsBinding.instance.addPostFrameCallback((_) => report());
      return;
    }
    late final AnimationStatusListener listener;
    listener = (status) {
      if (status.isCompleted) {
        animation.removeStatusListener(listener);
        report();
      }
    };
    animation.addStatusListener(listener);
  }

  /// 返回 true 时跳过 [didPopNext] 的重新获取播放器
  bool miniPlayerHandlesPopNext() {
    if (isShowing) {
      return true;
    }
    miniPlayerSession.close(pause: false);
    return false;
  }

  void onMiniAwarePopInvoked(bool didPop, Object? result) {
    if (didPop && miniPlayerSession.isActive) {
      return;
    }
    videoDetailController.plPlayerController.onPopInvokedWithResult(
      didPop,
      result,
    );
  }

  VoidCallback? get onShrinkToMiniPlayer =>
      MiniPlayerPolicy.isTabletLandscape(MediaQuery.sizeOf(context))
      ? () => miniPlayerSession.shrink(this)
      : null;

  @override
  bool get canEnterMiniPlayer {
    final ctr = videoDetailController;
    final player = ctr.plPlayerController;
    return mounted &&
        isShowing &&
        PlPlayerController.playOwner?.tag == ctr.heroTag &&
        MiniPlayerPolicy.isTabletLandscape(MediaQuery.sizeOf(context)) &&
        MiniPlayerPolicy.canLoadInMini(ctr.args) &&
        ctr.graphVersion == null &&
        !ctr.isQuerying &&
        ctr.autoPlay &&
        ctr.videoState.value &&
        player.videoController != null &&
        !player.isDesktopPip;
  }

  @override
  Rect? get miniPlayerRect {
    final box = videoDetailController.videoPlayerKey.currentContext
        ?.findRenderObject();
    if (box is RenderBox && box.attached && box.hasSize) {
      return box.localToGlobal(Offset.zero) & box.size;
    }
    return null;
  }

  @override
  String get miniTitle {
    final title = introController.videoDetail.value.title;
    if (title != null && title.isNotEmpty) {
      return title;
    }
    return videoDetailController.args['title'] ?? '';
  }

  @override
  String get miniCover => videoDetailController.cover.value;

  /// 播放全部时以当前项续接列表，恢复时详情页从当前项加载
  @override
  Map<String, dynamic> get miniArgs {
    final ctr = videoDetailController;
    return {
      ...ctr.args,
      'aid': ctr.aid,
      'bvid': ctr.bvid,
      'cid': ctr.cid.value,
      'cover': ctr.cover.value,
      'title': miniTitle,
      'videoType': ctr.videoType,
      'isVertical': ctr.isVertical.value,
      if (ctr.isPlayAll) ...{
        'oid': ctr.aid,
        'isContinuePlaying': true,
        'desc': ctr.mediaDesc,
      },
    };
  }

  @override
  MiniPlayerQueue get miniQueue {
    final ctr = videoDetailController;
    return MiniPlayerQueue.snapshot(
      bvid: ctr.bvid,
      detail: introController.videoDetail.value,
      mediaList: ctr.isPlayAll ? ctr.mediaList.toList() : null,
      args: miniArgs,
    );
  }

  @override
  PlayUrlModel get miniPlayUrl => videoDetailController.data;

  @override
  void onMiniCovered() {
    final player = videoDetailController.plPlayerController;
    if (player.isFullScreen.value) {
      player.triggerFullScreen(status: false);
    }
  }

  @override
  void onMiniDetached() {
    introController.cancelTimer();
    videoDetailController
      ..cancelBlockListener()
      ..makeHeartBeat();
    plPlayerController
      ?..removeStatusLister(playerListener)
      ..removePositionListener(positionListener);
  }

  @override
  void onMiniStopped({required bool resumeOnReturn}) {
    didPushNext();
    if (!resumeOnReturn) {
      videoDetailController.playerStatus = PlayerStatus.paused;
    }
  }

  @override
  void onMiniRevealed() => didPopNext();
}
