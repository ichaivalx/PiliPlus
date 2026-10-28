import 'package:PiliPlus/models_new/video/video_detail/page.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/services/service_locator.dart';

/// 小窗会话持有播放器期间的系统媒体信息与控制
class MiniPlayerMedia {
  MiniPlayerMedia(this._ownerTag);

  final String _ownerTag;
  _MediaControls? _savedControls;

  void updateItem({
    required Object? cid,
    required String title,
    required String cover,
    int? timeLength,
  }) {
    final handler = videoPlayerServiceHandler;
    if (handler == null || cid is! int) {
      return;
    }
    handler
      ..onVideoDetailDispose(_ownerTag)
      ..onVideoDetailChange(
        Part(
          cid: cid,
          part: title,
          duration: (timeLength ?? 0) ~/ 1000,
        ),
        cid,
        _ownerTag,
        cover: cover,
      );
    syncState();
  }

  /// 按实际播放状态刷新系统媒体状态
  void syncState() {
    final player = PlPlayerController.instance;
    if (player == null || player.videoPlayerController == null) {
      return;
    }
    videoPlayerServiceHandler?.onUpdateState(
      player.playerStatus,
      player.isBuffering.value,
      player.isLive,
      position: Duration(milliseconds: player.positionInMilliseconds),
      speed: player.playbackSpeed,
    );
  }

  /// 会话持有播放器期间，系统媒体控制由会话处理
  void takeControls() {
    final handler = videoPlayerServiceHandler;
    if (handler == null || _savedControls != null) {
      return;
    }
    _savedControls = (
      onPlay: handler.onPlay,
      onPause: handler.onPause,
      onSeek: handler.onSeek,
      onSkipToNext: handler.onSkipToNext,
      onSkipToPrevious: handler.onSkipToPrevious,
    );
    handler
      ..onPlay = null
      ..onPause = null
      ..onSeek = null
      ..onSkipToNext = null
      ..onSkipToPrevious = null;
  }

  void restoreControls() {
    final controls = _savedControls;
    _savedControls = null;
    if (controls != null) {
      videoPlayerServiceHandler
        ?..onPlay = controls.onPlay
        ..onPause = controls.onPause
        ..onSeek = controls.onSeek
        ..onSkipToNext = controls.onSkipToNext
        ..onSkipToPrevious = controls.onSkipToPrevious;
    }
  }
}

typedef _MediaControls = ({
  Future<void>? Function()? onPlay,
  Future<void>? Function()? onPause,
  Future<void>? Function(Duration position)? onSeek,
  void Function()? onSkipToNext,
  void Function()? onSkipToPrevious,
});
