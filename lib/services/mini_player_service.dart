import 'dart:async';
import 'dart:ui';

import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models/common/video/source_type.dart';
import 'package:PiliPlus/models/common/video/audio_quality.dart';
import 'package:PiliPlus/models/common/video/video_decode_type.dart';
import 'package:PiliPlus/models/common/video/video_quality.dart';
import 'package:PiliPlus/models/common/video/video_type.dart';
import 'package:PiliPlus/models/video/play/url.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/data_source.dart';
import 'package:PiliPlus/plugin/pl_player/models/heart_beat_type.dart';
import 'package:PiliPlus/services/service_locator.dart';
import 'package:PiliPlus/utils/connectivity_utils.dart';
import 'package:PiliPlus/utils/extension/iterable_ext.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/video_utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';

class MiniPlayerSnapshot {
  MiniPlayerSnapshot({
    required this.arguments,
    required this.plPlayerController,
    required this.title,
    required this.cover,
    required this.sourceRect,
    required this.data,
    required this.firstVideo,
    required this.currentVideoQa,
    required this.currentAudioQa,
    required this.currentDecodeFormats,
    required this.videoUrl,
    required this.audioUrl,
    required this.volume,
  });

  final Map<String, dynamic> arguments;
  final PlPlayerController plPlayerController;
  final Rect sourceRect;

  String title;
  String cover;
  PlayUrlModel data;
  VideoItem firstVideo;
  VideoQuality? currentVideoQa;
  AudioQuality? currentAudioQa;
  VideoDecodeFormatType currentDecodeFormats;
  String? videoUrl;
  String? audioUrl;
  Volume? volume;

  String get heroTag => arguments['heroTag'];
  int get cid => arguments['cid'];
  String get bvid => arguments['bvid'];
  int get aid => arguments['aid'];
  VideoType get videoType => arguments['videoType'];

  Duration get position =>
      plPlayerController.videoPlayerController?.state.position ?? Duration.zero;

  Map<String, dynamic> get restoreArguments => {
    ...arguments,
    'progress': position.inMilliseconds,
  };
}

class MiniPlayerService extends GetxController {
  static MiniPlayerService get ensureInitialized {
    if (Get.isRegistered<MiniPlayerService>()) {
      return Get.find<MiniPlayerService>();
    }
    return Get.put(MiniPlayerService(), permanent: true);
  }

  static MiniPlayerService? get instanceOrNull =>
      Get.isRegistered<MiniPlayerService>()
      ? Get.find<MiniPlayerService>()
      : null;

  static bool get isMiniActive => instanceOrNull?.isActive == true;

  final Rxn<MiniPlayerSnapshot> snapshot = Rxn<MiniPlayerSnapshot>();
  final RxBool visible = false.obs;
  final RxBool loading = false.obs;

  bool _restoring = false;
  Completer<void>? _replaceCompleter;
  int _epoch = 0;

  bool get isActive => visible.value && snapshot.value != null;
  bool get isRestoring => _restoring;

  bool isTabletLandscape(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return PlatformUtils.isMobile &&
        size.width > size.height &&
        size.shortestSide >= 600;
  }

  bool canStartFrom({
    required BuildContext context,
    required bool isUgc,
    required bool isFileSource,
    required bool isFullScreen,
    required bool isDesktopPip,
    required bool hasPlayer,
    required bool isNormalSource,
    required bool isQuerying,
    required bool isInteractive,
  }) {
    return isTabletLandscape(context) &&
        isUgc &&
        !isFileSource &&
        !isFullScreen &&
        !isDesktopPip &&
        isNormalSource &&
        !isQuerying &&
        !isInteractive &&
        hasPlayer;
  }

  bool ownsHeroTag(String heroTag) =>
      isActive && snapshot.value?.heroTag == heroTag;

  bool enter(MiniPlayerSnapshot nextSnapshot) {
    if (nextSnapshot.plPlayerController.videoController == null ||
        nextSnapshot.videoUrl == null) {
      return false;
    }
    nextSnapshot.plPlayerController.inAppMiniPlayerActive = true;
    videoPlayerServiceHandler?.enableBackgroundPlay = true;
    _epoch += 1;
    snapshot.value = nextSnapshot;
    visible.value = true;
    loading.value = false;
    videoPlayerServiceHandler?.onMiniPlayerVideoChange(
      cid: nextSnapshot.cid,
      heroTag: nextSnapshot.heroTag,
      title: nextSnapshot.title,
      cover: nextSnapshot.cover,
      duration: nextSnapshot.data.timeLength == null
          ? null
          : Duration(milliseconds: nextSnapshot.data.timeLength!),
    );
    return true;
  }

  Future<void> minimizeCurrentRoute() async {
    await Future<void>.delayed(Duration.zero);
    if (Get.currentRoute == '/videoV') {
      Get.back();
    }
  }

  bool shouldReplaceWith(Map<String, dynamic> arguments) {
    if (!isActive || _restoring || loading.value) {
      return false;
    }
    return arguments['videoType'] == VideoType.ugc &&
        arguments['pgcApi'] != true &&
        arguments['pgcItem'] == null &&
        (arguments['sourceType'] ?? SourceType.normal) == SourceType.normal;
  }

  Future<void> replaceWith(Map<String, dynamic> arguments) async {
    if (!shouldReplaceWith(arguments)) {
      return;
    }

    final current = snapshot.value;
    if (current != null &&
        current.cid == arguments['cid'] &&
        current.bvid == arguments['bvid']) {
      restore();
      return;
    }

    if (_replaceCompleter case final completer? when !completer.isCompleted) {
      return completer.future;
    }

    final completer = _replaceCompleter = Completer<void>();
    final epoch = _epoch;
    loading.value = true;
    try {
      final old = snapshot.value;
      old?.plPlayerController.makeHeartBeat(
        old.plPlayerController.positionInMilliseconds ~/ 1000,
        type: HeartBeatType.status,
        isManual: true,
      );

      final loaded = await _loadSnapshotFor(arguments, old, epoch);
      if (loaded != null && visible.value && _epoch == epoch) {
        loaded.plPlayerController.inAppMiniPlayerActive = true;
        snapshot.value = loaded;
        videoPlayerServiceHandler?.onMiniPlayerVideoChange(
          cid: loaded.cid,
          heroTag: loaded.heroTag,
          title: loaded.title,
          cover: loaded.cover,
          duration: loaded.data.timeLength == null
              ? null
              : Duration(milliseconds: loaded.data.timeLength!),
        );
      }
    } finally {
      loading.value = false;
      if (!completer.isCompleted) {
        completer.complete();
      }
      if (identical(_replaceCompleter, completer)) {
        _replaceCompleter = null;
      }
    }
  }

  Future<MiniPlayerSnapshot?> _loadSnapshotFor(
    Map<String, dynamic> arguments,
    MiniPlayerSnapshot? old,
    int epoch,
  ) async {
    final controller = old?.plPlayerController ?? PlPlayerController.instance;
    if (controller == null) {
      return null;
    }

    final videoType = arguments['videoType'] as VideoType;
    final aid = arguments['aid'] as int;
    final bvid = arguments['bvid'] as String;
    final cid = arguments['cid'] as int;

    if (controller.cacheVideoQa == null) {
      final isWiFi = await ConnectivityUtils.isWiFi;
      controller
        ..cacheVideoQa = isWiFi
            ? Pref.defaultVideoQa
            : Pref.defaultVideoQaCellular
        ..cacheAudioQa = isWiFi
            ? Pref.defaultAudioQa
            : Pref.defaultAudioQaCellular;
    }

    final result = await VideoHttp.videoUrl(
      avid: aid,
      bvid: bvid,
      cid: cid,
      tryLook: controller.tryLook,
      videoType: videoType,
      voiceBalance: controller.enableAudioNormalization,
    );

    if (result case Success(:final response)) {
      if (!visible.value || _epoch != epoch) {
        return null;
      }

      final source = _resolveSource(response, controller);
      if (source == null) {
        SmartDialog.showToast('视频资源不存在');
        return null;
      }

      await controller.setDataSource(
        NetworkSource(
          videoSource: source.videoUrl,
          audioSource: source.audioUrl,
        ),
        duration: response.timeLength == null
            ? null
            : Duration(milliseconds: response.timeLength!),
        isVertical: arguments['isVertical'] ?? false,
        aid: aid,
        bvid: bvid,
        cid: cid,
        autoplay: true,
        videoType: videoType,
        width: source.firstVideo.width,
        height: source.firstVideo.height,
        volume: response.volume,
      );

      if (!visible.value || _epoch != epoch) {
        return null;
      }

      return MiniPlayerSnapshot(
        arguments: {...arguments},
        plPlayerController: controller,
        title: arguments['title'] ?? '',
        cover: arguments['cover'] ?? '',
        sourceRect: old?.sourceRect ?? Rect.zero,
        data: response,
        firstVideo: source.firstVideo,
        currentVideoQa: source.currentVideoQa,
        currentAudioQa: source.currentAudioQa,
        currentDecodeFormats: source.currentDecodeFormats,
        videoUrl: source.videoUrl,
        audioUrl: source.audioUrl,
        volume: response.volume,
      );
    }

    result.toast();
    return null;
  }

  _ResolvedMiniSource? _resolveSource(
    PlayUrlModel data,
    PlPlayerController controller,
  ) {
    if (data.dash == null && data.durl != null) {
      final first = data.durl!.first;
      final videoUrl = VideoUtils.getCdnUrl(first.playUrls);
      final videoQuality = VideoQuality.fromCode(data.quality!);
      return _ResolvedMiniSource(
        firstVideo: VideoItem(
          id: data.quality!,
          baseUrl: videoUrl,
          codecs: 'avc1',
          quality: videoQuality,
        ),
        currentVideoQa: videoQuality,
        currentAudioQa: null,
        currentDecodeFormats: VideoDecodeFormatType.AVC,
        videoUrl: videoUrl,
        audioUrl: '',
      );
    }

    final videoList = data.dash?.video;
    if (videoList == null || videoList.isEmpty) {
      return null;
    }

    final curHighestVideoQa = videoList.first.quality.code;
    int targetVideoQa = curHighestVideoQa;
    if (data.acceptQuality?.isNotEmpty == true &&
        controller.cacheVideoQa! <= curHighestVideoQa) {
      targetVideoQa = data.acceptQuality!.findClosestTarget(
        (e) => e <= controller.cacheVideoQa!,
        (a, b) => a > b ? a : b,
      );
    }

    final supportFormats = data.supportFormats!;
    final currentDecodeFormats = VideoUtils.selectCodec(
      supportFormats
          .firstWhere(
            (e) => e.quality == targetVideoQa,
            orElse: () => supportFormats.first,
          )
          .codecs!,
      Pref.preferCodecs,
    );

    final videosList = videoList
        .where((e) => e.quality.code == targetVideoQa)
        .toList();
    final firstVideo = videosList.firstWhere(
      (e) => currentDecodeFormats.codes.any(e.codecs!.startsWith),
      orElse: () => videosList.first,
    );

    final videoUrl = VideoUtils.getCdnUrl(firstVideo.playUrls);

    String? audioUrl;
    AudioQuality? currentAudioQa;
    final audioList = data.dash?.audio;
    if (audioList != null && audioList.isNotEmpty) {
      final audioIds = audioList.map((map) => map.id!).toList();
      int closestNumber = audioIds.findClosestTarget(
        (e) => e <= controller.cacheAudioQa,
        (a, b) => a > b ? a : b,
      );
      if (!audioIds.contains(controller.cacheAudioQa) &&
          audioIds.any((e) => e > controller.cacheAudioQa)) {
        closestNumber = AudioQuality.k192.code;
      }
      final firstAudio = audioList.firstWhere(
        (e) => e.id == closestNumber,
        orElse: () => audioList.first,
      );
      audioUrl = VideoUtils.getCdnUrl(firstAudio.playUrls, isAudio: true);
      if (firstAudio.id case final int id?) {
        currentAudioQa = AudioQuality.fromCode(id);
      }
    } else {
      audioUrl = '';
    }

    return _ResolvedMiniSource(
      firstVideo: firstVideo,
      currentVideoQa: VideoQuality.fromCode(targetVideoQa),
      currentAudioQa: currentAudioQa,
      currentDecodeFormats: currentDecodeFormats,
      videoUrl: videoUrl,
      audioUrl: audioUrl,
    );
  }

  bool beginRestore() {
    final current = snapshot.value;
    if (current == null || _restoring) {
      return false;
    }
    _restoring = true;
    return true;
  }

  void restore() {
    final current = snapshot.value;
    if (current == null) {
      _restoring = false;
      return;
    }
    if (!_restoring) {
      _restoring = true;
    }
    Get.toNamed(
      '/videoV',
      arguments: current.restoreArguments,
      preventDuplicates: false,
    );
  }

  MiniPlayerSnapshot? takeRestoredSnapshot(String heroTag) {
    final current = snapshot.value;
    if (!_restoring || current == null || current.heroTag != heroTag) {
      return null;
    }
    PlPlayerController.updatePlayCount();
    visible.value = false;
    snapshot.value = null;
    _restoring = false;
    _epoch += 1;
    current.plPlayerController.inAppMiniPlayerActive = false;
    return current;
  }

  void close() {
    final current = snapshot.value;
    visible.value = false;
    snapshot.value = null;
    loading.value = false;
    _restoring = false;
    _epoch += 1;
    if (current != null) {
      current.plPlayerController.inAppMiniPlayerActive = false;
      current.plPlayerController.makeHeartBeat(
        current.plPlayerController.positionInMilliseconds ~/ 1000,
        type: HeartBeatType.status,
        isManual: true,
      );
      current.plPlayerController.dispose();
    }
  }
}

class _ResolvedMiniSource {
  const _ResolvedMiniSource({
    required this.firstVideo,
    required this.currentVideoQa,
    required this.currentAudioQa,
    required this.currentDecodeFormats,
    required this.videoUrl,
    required this.audioUrl,
  });

  final VideoItem firstVideo;
  final VideoQuality? currentVideoQa;
  final AudioQuality? currentAudioQa;
  final VideoDecodeFormatType currentDecodeFormats;
  final String videoUrl;
  final String? audioUrl;
}
