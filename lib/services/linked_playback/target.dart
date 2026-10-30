import 'package:PiliPlus/models_new/video/video_detail/episode.dart';
import 'package:PiliPlus/pages/video/controller.dart';
import 'package:PiliPlus/pages/video/introduction/ugc/controller.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/data_status.dart';
import 'package:PiliPlus/services/linked_playback/models.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';

/// 联动播放所操作的页面播放器
abstract class LinkedTarget {
  LinkedKind get kind;

  /// 页面仍持有播放器
  bool get isActive;

  /// 正在加载
  bool get isLoading;

  /// 已加载 [cid] 时的播放器
  Player? playerFor(int cid);

  /// 加载 [cid] 失败的原因
  String? failureFor(int cid);

  /// 页面记录的倍速
  double get rate;

  Future<void> setRate(double rate);

  Future<void> play();

  /// 恢复被音频打断暂停的播放，按页面原有方式（如在后台时等回到前台）
  void resume();

  Future<void> pause();

  Future<void> seek(Duration position);

  /// 在当前页面内切换到 [content]，不能切换时返回 false
  bool open(LinkedContent content);
}

/// 视频详情页共用的播放器
final class VideoLinkedTarget implements LinkedTarget {
  const VideoLinkedTarget();

  static PlPlayerController? get _controller => PlPlayerController.instance;

  @override
  LinkedKind get kind => LinkedKind.video;

  @override
  bool get isActive => _controller?.videoPlayerController != null;

  @override
  bool get isLoading => _controller?.processing ?? false;

  /// 页面已交出播放器（未交给小窗）时不再视为已加载，避免操作被覆盖页面的播放器
  @override
  Player? playerFor(int cid) {
    final controller = _controller;
    if (controller == null ||
        PlPlayerController.playOwner == null ||
        controller.isLive ||
        controller.cid != cid ||
        !controller.dataStatus.loaded) {
      return null;
    }
    final player = controller.videoPlayerController;
    if (player == null || player.disposed) {
      return null;
    }
    return player;
  }

  @override
  String? failureFor(int cid) {
    final controller = _controller;
    if (controller != null &&
        controller.cid == cid &&
        controller.dataStatus.error) {
      return '视频加载失败';
    }
    return null;
  }

  @override
  double get rate => _controller?.playbackSpeed ?? 1.0;

  @override
  Future<void> setRate(double rate) async {
    await _controller?.setPlaybackSpeed(rate);
  }

  @override
  Future<void> play() async {
    await _controller?.play();
  }

  @override
  void resume() => PlPlayerController.resumeIfExists();

  @override
  Future<void> pause() async {
    await _controller?.pause(isInterrupt: true);
  }

  @override
  Future<void> seek(Duration position) async {
    await _controller?.seek(position);
  }

  /// 持有播放器的是普通视频详情页（非播放全部）且已在播放时在页内切换
  @override
  bool open(LinkedContent content) {
    final owner = PlPlayerController.playOwner;
    if (owner == null ||
        owner.type != UgcIntroController ||
        !Get.isRegistered<VideoDetailController>(tag: owner.tag) ||
        !Get.isRegistered<UgcIntroController>(tag: owner.tag)) {
      return false;
    }
    final detail = Get.find<VideoDetailController>(tag: owner.tag);
    if (!detail.autoPlay || detail.isPlayAll || detail.isFileSource) {
      return false;
    }
    if (detail.cid.value != content.cid) {
      Get.find<UgcIntroController>(tag: owner.tag).onChangeEpisode(
        BaseEpisodeItem(
          aid: content.aid,
          bvid: content.bvid,
          cid: content.cid,
          cover: content.cover,
          title: content.title,
        ),
      );
    } else if (!detail.isQuerying && !isLoading) {
      detail.queryVideoUrl();
    }
    return true;
  }
}
