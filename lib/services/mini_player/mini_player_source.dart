import 'dart:io' show Platform;

import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models/common/video/base_quality.dart';
import 'package:PiliPlus/models/common/video/video_type.dart';
import 'package:PiliPlus/models/video/play/url.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/utils/connectivity_utils.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/video_utils.dart';

typedef MiniPlayerSource = ({
  PlayUrlModel data,
  VideoItem video,
  String videoUrl,
  String audioUrl,
});

/// 按详情页相同的画质、音质、编码偏好选取播放源
abstract final class MiniPlayerSourceResolver {
  /// 返回 null 表示仅有 durl 等需要详情页处理的资源
  static Future<LoadingState<MiniPlayerSource?>> resolve(
    PlPlayerController player, {
    required int aid,
    required String bvid,
    required int cid,
  }) async {
    var preferCodecs = Pref.preferCodecs;
    if (PlatformUtils.isMobile || Platform.isLinux) {
      final isWiFi = await ConnectivityUtils.isWiFi;
      if (player.cacheVideoQa == null) {
        player
          ..cacheVideoQa = isWiFi
              ? Pref.defaultVideoQa
              : Pref.defaultVideoQaCellular
          ..cacheAudioQa = isWiFi
              ? Pref.defaultAudioQa
              : Pref.defaultAudioQaCellular;
      }
      preferCodecs = isWiFi ? Pref.preferCodecs : Pref.preferCodecsCellular;
    }

    Future<LoadingState<PlayUrlModel>> request(int quality) =>
        VideoHttp.videoUrl(
          avid: aid,
          bvid: bvid,
          cid: cid,
          qn: quality,
          tryLook: player.tryLook,
          videoType: VideoType.ugc,
          voiceBalance: player.enableAudioNormalization,
        );

    final PlayUrlModel data;
    switch (await request(VideoQuality.hdrVivid.code)) {
      case Success(:final response):
        data = response;
      case final Error error:
        return error;
      case Loading():
        return LoadingState.loading();
    }

    final dash = data.dash;
    if (dash == null || dash.video?.isNotEmpty != true) {
      return const Success(null);
    }

    final missingQuality = data.missingVideoQualityBelowHighest;
    if (missingQuality != -1) {
      if (await request(missingQuality) case Success(:final response)) {
        dash.video!.merge(response.dash?.video);
      }
    }

    final video = VideoUtils.findTargetVideo(
      dash.video!,
      player.cacheVideoQa!,
      data.acceptQuality,
      data.supportFormats!,
      preferCodecs,
    ).$4;

    var audioUrl = '';
    if (dash.audio case final audioList? when audioList.isNotEmpty) {
      final audio = VideoUtils.findTargetAudio(audioList, player.cacheAudioQa);
      audioUrl = VideoUtils.getCdnUrl(audio.playUrls, isAudio: true);
    }

    return Success((
      data: data,
      video: video,
      videoUrl: VideoUtils.getCdnUrl(video.playUrls),
      audioUrl: audioUrl,
    ));
  }
}
