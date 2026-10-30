import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/services/linked_playback/linked_playback.dart';
import 'package:PiliPlus/services/shutdown_timer_service.dart';
import 'package:audio_session/audio_session.dart';

class AudioSessionHandler {
  late AudioSession session;
  /// 被打断后待恢复，定时关闭到期时取消
  ShutdownLoad? _interruptResume;

  /// 打断开始时正在播放，结束时需恢复播放；否则只恢复进行中加载的自动播放
  bool _interruptedPlayback = false;

  /// 暂停播放，并暂缓进行中的加载（如小窗切换视频）完成后的自动播放
  void _beginInterrupt(bool playing) {
    if (playing) {
      PlPlayerController.pauseIfExists(isInterrupt: true);
    }
    // 永久失去焦点时没有结束事件，旧的待恢复以本次打断为准
    _takeInterruptResume();
    shutdownTimerService.holdPendingAutoplay();
    _interruptResume = shutdownTimerService.beginLoad();
    _interruptedPlayback = playing;
  }

  ShutdownLoad? _takeInterruptResume() {
    final resume = _interruptResume;
    if (resume != null) {
      _interruptResume = null;
      shutdownTimerService.endLoad(resume);
    }
    return resume;
  }

  Future<bool> setActive(bool active) {
    return session.setActive(active);
  }

  AudioSessionHandler() {
    initSession();
  }

  Future<void> initSession() async {
    session = await AudioSession.instance;
    session.configure(const AudioSessionConfiguration.music());

    session.interruptionEventStream.listen((event) {
      final playerStatus = PlPlayerController.getPlayerStatusIfExists();
      // final player = PlPlayerController.getInstance();
      if (event.begin) {
        final playing = playerStatus == PlayerStatus.playing;
        if (!playing &&
            (event.type == AudioInterruptionType.duck ||
                !shutdownTimerService.hasPendingAutoplay)) {
          return;
        }
        // if (!player.playerStatus.playing) return;
        switch (event.type) {
          case AudioInterruptionType.duck:
            PlPlayerController.setVolumeIfExists(
              (PlPlayerController.getVolumeIfExists() ?? 0) * 0.5,
              showIndicator: false,
            );
            // player.setVolume(player.volume.value * 0.5);
            break;
          case AudioInterruptionType.pause:
            _beginInterrupt(playing);
            // player.pause(isInterrupt: true);
            break;
          case AudioInterruptionType.unknown:
            _beginInterrupt(playing);
            // player.pause(isInterrupt: true);
            break;
        }
      } else {
        final resume = _takeInterruptResume();
        switch (event.type) {
          case AudioInterruptionType.duck:
            PlPlayerController.setVolumeIfExists(
              (PlPlayerController.getVolumeIfExists() ?? 0) * 2,
              showIndicator: false,
            );
            // player.setVolume(player.volume.value * 2);
            break;
          case AudioInterruptionType.pause:
            if (resume != null && shutdownTimerService.canAutoplay(resume)) {
              shutdownTimerService.releasePendingAutoplay();
              // 联动跟随时恢复当前跟随内容的播放器：打断期间主控可能已切换到
              // 听视频，原视频播放器已释放
              if (_interruptedPlayback && !linkedPlayback.resumeInterrupted()) {
                PlPlayerController.resumeIfExists();
              }
            }
            //player.play();
            break;
          case AudioInterruptionType.unknown:
            break;
        }
      }
    });

    // 耳机拔出暂停
    session.becomingNoisyEventStream.listen((_) {
      // 已暂停时同样取消回到前台、打断结束后的自动恢复
      shutdownTimerService.cancelPendingAutoplay();
      PlPlayerController.pauseIfExists();
      // final player = PlPlayerController.getInstance();
      // if (player.playerStatus.playing) {
      //   player.pause();
      // }
    });
  }
}
