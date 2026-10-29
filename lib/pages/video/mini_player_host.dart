import 'dart:async' show Completer, StreamSubscription, Timer;
import 'dart:io' show Platform;
import 'dart:ui' as ui;

import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/pages/common/common_intro_controller.dart';
import 'package:PiliPlus/pages/video/controller.dart';
import 'package:PiliPlus/pages/video/introduction/ugc/controller.dart';
import 'package:PiliPlus/pages/video/related/controller.dart';
import 'package:PiliPlus/pages/video/reply/controller.dart';
import 'package:PiliPlus/pages/video/view.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/plugin/pl_player/utils/fullscreen.dart';
import 'package:PiliPlus/services/mini_player/mini_player_host_layer.dart';
import 'package:PiliPlus/services/mini_player/mini_player_policy.dart';
import 'package:PiliPlus/services/mini_player/mini_player_session.dart';
import 'package:PiliPlus/services/shutdown_timer_service.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:screen_brightness_platform_interface/screen_brightness_platform_interface.dart';

/// 详情页播放器以外的各区域所需的内容
enum MiniRestoreContent { intro, related, replies }

mixin MiniPlayerHostMixin on State<VideoDetailPageV>, RouteAware
    implements MiniPlayerHost {
  VideoDetailController get videoDetailController;
  CommonIntroController get introController;
  PlPlayerController? get plPlayerController;
  set plPlayerController(PlPlayerController? value);
  bool get isShowing;
  Future<void> playerListener(PlayerStatus status);
  void positionListener(Duration position);
  Future<void>? playCallBack();

  /// 所在的宿主，不在宿主中（手机、桌面等）时为 null
  MiniPlayerHostEntry? get _host => MiniPlayerHostScope.maybeOf(context);

  /// 构建时不显示：不自动全屏，不修改系统栏
  bool get miniStartsHidden => _host?.hidden ?? false;

  /// 显示中的其他详情页离开前不接管播放器
  bool get miniDefersPlayer => _host?.deferPlayer ?? false;

  /// 不显示地构建时，各区域实际显示的内容，首次显示前等待其到达
  final Set<MiniRestoreContent> _shownContents = {};

  StreamSubscription? _detailSubscription;

  void initMiniPlayerHost() {
    final host = _host;
    if (host == null) {
      return;
    }
    miniPlayerSession.attach(host, this);
    if (host.hidden) {
      // 在小窗中开始播放，回到上一个视频时同样从离开时的进度继续
      videoDetailController.autoPlay = true;
    }
    // 只能在详情页中播放的内容不留在小窗中
    _detailSubscription = introController.videoDetail.listen((detail) {
      if (detail.rights?.isSteinGate == 1) {
        miniPlayerSession.showDetail(this);
      }
    });
  }

  /// 被移除时先作废等待中的续播
  void disposeMiniPlayerHost() {
    _detailSubscription?.cancel();
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

  String get miniHeroTag => videoDetailController.heroTag;

  /// 返回 true 时跳过 [didPopNext] 的重新获取播放器
  bool miniPlayerHandlesPopNext() {
    if (isShowing) {
      return true;
    }
    if (_takeReturnResume() case final resume?
        when !shutdownTimerService.canAutoplay(resume)) {
      videoDetailController.playerStatus = PlayerStatus.paused;
    }
    return false;
  }

  /// 宿主中的详情页只在关闭时收到出栈，收起与回到上一个视频不经过这里
  void onMiniAwarePopInvoked(bool didPop, Object? result) => videoDetailController
      .plPlayerController
      .onPopInvokedWithResult(didPop, result);

  VoidCallback? get onShrinkToMiniPlayer =>
      _host != null &&
          MiniPlayerPolicy.isTabletLandscape(MediaQuery.sizeOf(context))
      ? () => miniPlayerSession.collapse(this)
      : null;

  @override
  bool get canEnterMiniPlayer {
    final ctr = videoDetailController;
    final player = ctr.plPlayerController;
    return mounted &&
        _host != null &&
        isShowing &&
        PlPlayerController.playOwner?.tag == ctr.heroTag &&
        MiniPlayerPolicy.isTabletLandscape(MediaQuery.sizeOf(context)) &&
        _canPlayInMini &&
        ctr.autoPlay &&
        ctr.videoState.value &&
        player.videoController != null &&
        !player.isDesktopPip;
  }

  /// 互动视频的剧情选择只在详情页中显示，简介中的标记先于剧情图可用
  bool get _canPlayInMini {
    final ctr = videoDetailController;
    return MiniPlayerPolicy.canLoadInMini(ctr.args) &&
        ctr.graphVersion == null &&
        introController.videoDetail.value.rights?.isSteinGate != 1;
  }

  @override
  bool get isMiniPlayerLoading => !videoDetailController.videoState.value;

  /// 页面内容的根节点，位于转场动画的变换之内
  RenderRepaintBoundary? get _pageBoundary =>
      context.findAncestorRenderObjectOfType<RenderRepaintBoundary>();

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

  /// 播放全部时以当前项续接列表，重新打开时详情页从当前项加载
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
      // 对应 `CommonIntroController.onInit`，重新打开时保留本次的稍后再看操作
      'viewLater': introController.hasLater.value,
      if (ctr.isPlayAll) ...{
        'oid': ctr.aid,
        'isContinuePlaying': true,
        'desc': ctr.mediaDesc,
      },
    };
  }

  @override
  void onMiniCollapsed() {
    final ctr = videoDetailController;
    final player = ctr.plPlayerController;
    if (player.isFullScreen.value) {
      player.triggerFullScreen(status: false);
    }
    // 对应 didPushNext：页面不再显示时恢复应用亮度与系统栏
    if (Platform.isAndroid && !ctr.setSystemBrightness) {
      ctr.brightness = player.brightness.value;
      ScreenBrightnessPlatform.instance.resetApplicationScreenBrightness();
    }
    if (ctr.removeSafeArea) {
      showSystemBar();
    }
  }

  @override
  void onMiniExpanded() {
    final ctr = videoDetailController;
    // 对应 didPopNext 中的亮度恢复
    if (Platform.isAndroid && !ctr.setSystemBrightness) {
      final brightness = ctr.brightness;
      if (brightness != null && brightness != -1.0) {
        plPlayerController?.brightness.value = brightness;
        ScreenBrightnessPlatform.instance.setApplicationScreenBrightness(
          brightness,
        );
      } else {
        ScreenBrightnessPlatform.instance.resetApplicationScreenBrightness();
      }
    }
    if (ctr.removeSafeArea) {
      hideSystemBar();
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
  void onMiniDetached() {
    _cancelContinuation();
    introController.cancelTimer();
    videoDetailController
      ..cancelBlockListener()
      ..makeHeartBeat();
    plPlayerController
      ?..removeStatusLister(playerListener)
      ..removePositionListener(positionListener);
    if (PlPlayerController.playOwner?.tag == miniHeroTag) {
      PlPlayerController.setPlayCallBack(null);
    }
  }

  /// 对应页面初始化时获取播放器：初始化期间请求的播放地址此时才加载
  @override
  void takeOverPlayer() {
    if (!mounted) {
      return;
    }
    final ctr = videoDetailController;
    PlPlayerController.setPlayCallBack(
      playCallBack,
      playOwner: (tag: ctr.heroTag, type: introController.runtimeType),
    );
    plPlayerController = ctr.plPlayerController
      ..addStatusLister(playerListener)
      ..addPositionListener(positionListener);
    if (!ctr.isQuerying && ctr.videoUrl != null) {
      ctr.playerInit();
    }
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

  /// 简介、相关视频、评论各区域：不显示地构建的页面首次显示时，[content]
  /// 尚未到达的区域留空，到达（或等待超时）后构建并淡入。各布局在构建
  /// 这些区域时调用，只有当前尺寸下实际显示的区域参与等待
  Widget afterMiniRestore({
    required Set<MiniRestoreContent> content,
    required Widget child,
  }) {
    final host = _host;
    if (host == null || !host.hidden) {
      return child;
    }
    _shownContents.addAll(content);
    if (content.every(_isRestoreReady)) {
      return child;
    }
    return _MiniRestoreReveal(
      host: this,
      entry: host,
      waiting: content,
      child: child,
    );
  }

  /// 首次构建后，实际显示的区域所需的内容都已到达时完成，最长等待
  /// [MiniPlayerMotion.revealTimeout]
  @override
  Future<void> whenMiniContentReady() async {
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || _shownContents.every(_isRestoreReady)) {
      return;
    }
    final completer = Completer<void>();
    void check() {
      if (!completer.isCompleted &&
          (!mounted || _shownContents.every(_isRestoreReady))) {
        completer.complete();
      }
    }

    final subscriptions = [
      for (final e in _shownContents)
        for (final source in _restoreSources(e)) source.listen((_) => check()),
    ];
    final timer = Timer(MiniPlayerMotion.revealTimeout, () {
      if (!completer.isCompleted) {
        completer.complete();
      }
    });
    await completer.future;
    timer.cancel();
    for (final e in subscriptions) {
      e.cancel();
    }
  }

  /// 简介区域含详情、标签与 UP 主信息
  List<Rx<Object?>> _restoreSources(MiniRestoreContent content) =>
      switch (content) {
        .intro => [
          introController.videoDetail,
          introController.videoTags,
          if (introController case UgcIntroController(:final userStat))
            userStat,
        ],
        .related => [
          if (Get.isRegistered<RelatedController>(tag: miniHeroTag))
            Get.find<RelatedController>(tag: miniHeroTag).loadingState,
        ],
        .replies => [
          if (Get.isRegistered<VideoReplyController>(tag: miniHeroTag))
            Get.find<VideoReplyController>(tag: miniHeroTag).loadingState,
        ],
      };

  /// 标签、UP 主信息请求失败时按超时显示
  bool _isRestoreReady(MiniRestoreContent content) => switch (content) {
    .intro =>
      introController.videoDetail.value.bvid != null &&
          introController.videoTags.value != null &&
          _isOwnerReady,
    _ => _restoreSources(content).every((e) => e.value is! Loading),
  };

  /// 对应 `UgcIntroController.queryUserStat`：合作视频的成员在详情中，
  /// 单个 UP 主的信息另行获取
  bool get _isOwnerReady =>
      (introController.videoDetail.value.staff?.isNotEmpty ?? false) ||
      switch (introController) {
        UgcIntroController(:final userStat) => userStat.value.card != null,
        _ => true,
      };
}

/// 不显示地构建的页面中尚未到达的区域：不显示期间到达时直接构建；首次显示时
/// 仍未到达则留空，显示动画结束且内容到达（或等待超时）后构建并以短促的
/// 淡入、上移出现
class _MiniRestoreReveal extends StatefulWidget {
  const _MiniRestoreReveal({
    required this.host,
    required this.entry,
    required this.waiting,
    required this.child,
  });

  final MiniPlayerHostMixin host;
  final MiniPlayerHostEntry entry;
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
    _waiting = [
      for (final e in widget.waiting)
        for (final source in widget.host._restoreSources(e))
          source.listen((_) => _check()),
      miniPlayerSession.restoring.listen((_) => _check()),
    ];
    widget.entry.addListener(_check);
  }

  bool get _ready => widget.waiting.every(widget.host._isRestoreReady);

  void _check() {
    if (_waiting == null) {
      return;
    }
    if (!widget.entry.painted) {
      // 不显示期间到达的内容直接构建
      if (_ready) {
        _stopWaiting();
        setState(() {});
      }
      return;
    }
    // 首次显示时开始计时，超时后按页面原样显示
    _timeout ??= Timer(MiniPlayerMotion.revealTimeout, _check);
    if ((_timeout!.isActive && !_ready) || miniPlayerSession.restoring.value) {
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
    widget.entry.removeListener(_check);
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
