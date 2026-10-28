import 'dart:async' show StreamSubscription, Timer;
import 'dart:ui' as ui;

import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models/video/play/url.dart';
import 'package:PiliPlus/pages/common/common_intro_controller.dart';
import 'package:PiliPlus/pages/video/controller.dart';
import 'package:PiliPlus/pages/video/introduction/ugc/controller.dart';
import 'package:PiliPlus/pages/video/related/controller.dart';
import 'package:PiliPlus/pages/video/reply/controller.dart';
import 'package:PiliPlus/pages/video/view.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/services/mini_player/mini_player_policy.dart';
import 'package:PiliPlus/services/mini_player/mini_player_queue.dart';
import 'package:PiliPlus/services/mini_player/mini_player_session.dart';
import 'package:PiliPlus/services/shutdown_timer_service.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

/// 横屏布局中播放器以外的区域所需的内容
enum MiniRestoreContent { intro, related, replies }

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

  /// 从小窗恢复时首屏尚未获取的内容，所在区域到达后再出现；
  /// null 表示页面不是从小窗恢复的
  Set<MiniRestoreContent>? _restoreWaiting;

  /// 随页面初始化提前加载的评论
  VideoReplyController? _restoreReplies;

  /// 交接的首页评论在下一个微任务中生效，生效后再开始恢复动画
  bool _applyingReplies = false;

  void initMiniPlayerHost() {
    miniRoute = Get.routing.route;
    miniPlayerSession.attach(this);
    if (miniPlayerSession.isRestoreTarget(miniHeroTag)) {
      videoDetailController.autoPlay = true;
      final waiting = _restoreWaiting = _takeMiniPrefetch();
      // 立即接管播放器，先展示小窗已有的视频详情
      final detail = miniPlayerSession.handOver(this);
      if (detail != null && detail.bvid == videoDetailController.bvid) {
        introController.videoDetail.value = detail;
        // 对应 `UgcIntroController.queryVideoIntro`，首页评论据此过滤简介
        _restoreReplies?.intro = detail.desc?.trim();
      } else {
        waiting.add(.intro);
      }
      _reportRestoreRect();
    }
  }

  /// 沿用小窗预先获取的首屏内容，未获取到的随页面初始化立即请求；
  /// 返回仍需等待的内容
  Set<MiniRestoreContent> _takeMiniPrefetch() {
    final waiting = <MiniRestoreContent>{};
    final prefetch = miniPlayerSession.prefetchFor(miniHeroTag);
    final bvid = videoDetailController.bvid;
    if (prefetch == null || prefetch.bvid != bvid) {
      return waiting;
    }
    if (prefetch.showsRelated) {
      final related = prefetch.related;
      final controller = Get.put(
        RelatedController(autoQuery: related == null, bvid: bvid),
        tag: miniHeroTag,
      );
      if (related != null) {
        controller.loadingState.value = related;
      } else {
        waiting.add(.related);
      }
    }
    if (prefetch.showsReplies) {
      final controller = _restoreReplies = Get.find<VideoReplyController>(
        tag: miniHeroTag,
      );
      _applyingReplies = prefetch.replies(controller.mode) != null;
      if (!_applyingReplies) {
        waiting.add(.replies);
      }
      controller.queryData();
    }
    return waiting;
  }

  /// 覆盖中被移除时先由会话接续等待中的续播
  void disposeMiniPlayerHost() {
    miniPlayerSession.detach(this);
    _cancelContinuation();
    _takeReturnResume();
  }

  /// 返回时按离开时的播放状态恢复，期间定时关闭到期等停止意图使其取消
  ShutdownLoad? _returnResume;

  ShutdownLoad? _takeReturnResume() {
    final resume = _returnResume;
    if (resume != null) {
      _returnResume = null;
      shutdownTimerService.endLoad(resume);
    }
    return resume;
  }

  /// 页面正常离开（未交给小窗）：交出播放所有权并作废续播，进行中的加载
  /// 因不再持有播放器而不会播放，重新露出时由 didPopNext 重新获取
  void onLeaveWithoutMiniPlayer() {
    _cancelContinuation();
    _takeReturnResume();
    // 与 didPushNext 保存、didPopNext 据以恢复的播放状态一致
    if (plPlayerController?.playerStatus.isPlaying ?? false) {
      _returnResume = shutdownTimerService.beginLoad();
    }
    plPlayerController?.cancelBackgroundResume();
    if (PlPlayerController.playOwner?.tag == miniHeroTag) {
      PlPlayerController.setPlayCallBack(null);
    }
  }

  /// 横屏布局中播放器以外的区域：从小窗恢复时，[content] 均已交接的区域在
  /// 首帧构建，其余留空，恢复动画结束且内容到达后再构建并淡入
  Widget afterMiniRestore({
    double? width,
    double? height,
    required Set<MiniRestoreContent> content,
    required Widget child,
  }) {
    final waiting = _restoreWaiting?.intersection(content);
    return SizedBox(
      width: width,
      height: height,
      child: waiting == null
          ? child
          : _MiniRestoreReveal(host: this, waiting: waiting, child: child),
    );
  }

  Rx<Object?> _restoreSource(MiniRestoreContent content) => switch (content) {
    .intro => introController.videoDetail,
    .related => Get.find<RelatedController>(tag: miniHeroTag).loadingState,
    .replies => Get.find<VideoReplyController>(tag: miniHeroTag).loadingState,
  };

  bool _isRestoreReady(MiniRestoreContent content) => switch (content) {
    .intro => introController.videoDetail.value.bvid != null,
    _ => _restoreSource(content).value is! Loading,
  };

  /// 播放器完成布局、交接的内容生效后再上报，避免以空区域作为恢复动画的终点，
  /// 也避免首次构建交接的内容落在动画的第一帧
  void _reportRestoreRect() {
    WidgetsBinding.instance
      ..addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        final applying =
            _applyingReplies &&
            _restoreReplies!.loadingState.value is Loading &&
            miniPlayerSession.restoring.value;
        if (applying || !miniPlayerSession.reportRestoreRect(this)) {
          _reportRestoreRect();
        }
      })
      ..scheduleFrame();
  }

  /// 页面内容的根节点，位于转场动画的变换之内
  RenderRepaintBoundary? get _pageBoundary =>
      context.findAncestorRenderObjectOfType<RenderRepaintBoundary>();

  /// 返回 true 时跳过 [didPopNext] 的重新获取播放器
  bool miniPlayerHandlesPopNext() {
    if (isShowing) {
      return true;
    }
    if (_takeReturnResume() case final resume?
        when !shutdownTimerService.canAutoplay(resume)) {
      videoDetailController.playerStatus = PlayerStatus.paused;
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
        canHandOffToMini &&
        ctr.autoPlay &&
        ctr.videoState.value &&
        player.videoController != null &&
        !player.isDesktopPip;
  }

  /// 互动视频的剧情图需另行请求，简介中的标记先于其可用；
  /// 切换分P等加载期间页面信息与播放源不一致，不能交给小窗
  @override
  bool get canHandOffToMini {
    final ctr = videoDetailController;
    return MiniPlayerPolicy.canLoadInMini(ctr.args) &&
        ctr.graphVersion == null &&
        introController.videoDetail.value.rights?.isSteinGate != 1 &&
        !ctr.isQuerying &&
        ctr.plPlayerController.cid == ctr.cid.value;
  }

  /// 相对页面根节点计算，转场缩放期间也是页面静止时的位置
  @override
  Rect? get miniPlayerRect {
    final box = videoDetailController.videoPlayerKey.currentContext
        ?.findRenderObject();
    if (box is RenderBox &&
        box.attached &&
        box.hasSize &&
        !box.size.isEmpty) {
      return box.localToGlobal(Offset.zero, ancestor: _pageBoundary) &
          box.size;
    }
    return null;
  }

  @override
  ui.Image? captureMiniSnapshot() {
    try {
      return _pageBoundary?.toImageSync(
        pixelRatio: MediaQuery.devicePixelRatioOf(context),
      );
    } catch (_) {
      return null;
    }
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
  MiniPlayerQueue createMiniQueue() {
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

  /// 作废页面进行中的自动续播，避免之后操作已交出的播放器；
  /// 返回是否有等待中的续播
  bool _cancelContinuation() {
    if (introController case final UgcIntroController controller) {
      return controller.cancelContinuation();
    }
    return false;
  }

  @override
  bool onMiniDetached() {
    final continuing = _cancelContinuation();
    introController.cancelTimer();
    videoDetailController
      ..cancelBlockListener()
      ..makeHeartBeat();
    plPlayerController
      ?..removeStatusLister(playerListener)
      ..removePositionListener(positionListener);
    return continuing;
  }

  @override
  void onMiniStopped({required bool resumeOnReturn}) {
    didPushNext();
    if (!resumeOnReturn) {
      videoDetailController.playerStatus = PlayerStatus.paused;
    }
  }

  @override
  void onMiniRevealed() {
    if (!isShowing) {
      didPopNext();
    }
  }

  @override
  void onMiniHidden() {
    if (isShowing) {
      didPushNext();
    }
  }
}

/// 内容已交接时直接构建；否则恢复期间先留空，恢复动画结束且内容到达
/// （或等待超时）后构建内容并以短促的淡入、上移出现
class _MiniRestoreReveal extends StatefulWidget {
  const _MiniRestoreReveal({
    required this.host,
    required this.waiting,
    required this.child,
  });

  final MiniPlayerHostMixin host;
  final Set<MiniRestoreContent> waiting;
  final Widget child;

  @override
  State<_MiniRestoreReveal> createState() => _MiniRestoreRevealState();
}

class _MiniRestoreRevealState extends State<_MiniRestoreReveal>
    with SingleTickerProviderStateMixin {
  List<StreamSubscription>? _waiting;
  Timer? _timeout;
  AnimationController? _controller;
  Animation<double>? _progress;

  @override
  void initState() {
    super.initState();
    if (miniPlayerSession.restoring.value && !_ready) {
      _waiting = [
        for (final e in widget.waiting)
          widget.host._restoreSource(e).listen((_) => _check()),
        miniPlayerSession.restoring.listen((_) => _check()),
      ];
      _timeout = Timer(MiniPlayerMotion.revealTimeout, _check);
    }
  }

  bool get _ready => widget.waiting.every(widget.host._isRestoreReady);

  /// 超时后按页面原样显示
  void _check() {
    if (_waiting == null ||
        (_timeout!.isActive && !_ready) ||
        miniPlayerSession.restoring.value) {
      return;
    }
    _stopWaiting();
    _reveal();
  }

  void _stopWaiting() {
    _timeout?.cancel();
    for (final e in _waiting ?? const <StreamSubscription>[]) {
      e.cancel();
    }
    _waiting = null;
  }

  void _reveal() {
    final controller = _controller = AnimationController(
      vsync: this,
      duration: MiniPlayerMotion.revealDuration,
    );
    setState(() {
      _progress = CurvedAnimation(
        parent: controller,
        curve: MiniPlayerMotion.curve,
      );
    });
    controller.forward();
  }

  @override
  void dispose() {
    _stopWaiting();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_waiting != null) {
      return const SizedBox.shrink();
    }
    final progress = _progress;
    if (progress == null) {
      return widget.child;
    }
    return FadeTransition(
      opacity: progress,
      child: AnimatedBuilder(
        animation: progress,
        builder: (context, child) => Transform.translate(
          offset: Offset(
            0,
            MiniPlayerMotion.revealOffset * (1 - progress.value),
          ),
          child: child,
        ),
        child: widget.child,
      ),
    );
  }
}
