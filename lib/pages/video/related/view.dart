import 'package:PiliPlus/common/widgets/loading_widget/http_error.dart';
import 'package:PiliPlus/common/widgets/video_card/video_card_h.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models/model_hot_video_item.dart';
import 'package:PiliPlus/models_new/video/video_detail/episode.dart';
import 'package:PiliPlus/pages/video/controller.dart';
import 'package:PiliPlus/pages/video/introduction/ugc/controller.dart';
import 'package:PiliPlus/pages/video/related/controller.dart';
import 'package:PiliPlus/utils/extension/get_ext.dart';
import 'package:PiliPlus/utils/grid.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class RelatedVideoPanel extends StatefulWidget {
  const RelatedVideoPanel({super.key, required this.heroTag});
  final String heroTag;
  @override
  State<RelatedVideoPanel> createState() => _RelatedVideoPanelState();
}

class _RelatedVideoPanelState extends State<RelatedVideoPanel> with GridMixin {
  late final RelatedController _relatedController;
  late final VideoDetailController _videoDetailController;
  late final UgcIntroController _ugcIntroController;

  @override
  void initState() {
    super.initState();
    _videoDetailController = Get.find<VideoDetailController>(
      tag: widget.heroTag,
    );
    _ugcIntroController = Get.find<UgcIntroController>(tag: widget.heroTag);
    final initialState =
        _videoDetailController.restoredMiniSnapshot?.relatedVideoState;
    _relatedController = Get.putOrFind(
      () => RelatedController(
        autoQuery: initialState == null || initialState is Loading,
        initialState: initialState,
      ),
      tag: widget.heroTag,
    );
  }

  Future<void> _openRelatedVideo(HotVideoItemModel videoItem) async {
    if (videoItem.isPugv ?? false) {
      PageUtils.viewPugv(seasonId: videoItem.seasonId);
      return;
    }

    if (videoItem.isLive ?? false) {
      if (videoItem.roomId case final roomId?) {
        PageUtils.toLiveRoom(roomId);
      }
      return;
    }

    if (videoItem.redirectUrl?.isNotEmpty == true &&
        PageUtils.viewPgcFromUri(videoItem.redirectUrl!)) {
      return;
    }

    await _ugcIntroController.onChangeEpisode(
      BaseEpisodeItem(
        aid: videoItem.aid,
        bvid: videoItem.bvid,
        cid: videoItem.cid,
        cover: videoItem.cover,
        title: videoItem.title,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: const EdgeInsets.only(top: 7, bottom: 100),
      sliver: Obx(() => _buildBody(_relatedController.loadingState.value)),
    );
  }

  Widget _buildBody(LoadingState<List<HotVideoItemModel>?> loadingState) {
    return switch (loadingState) {
      Loading() => gridSkeleton,
      Success(:final response) =>
        response != null && response.isNotEmpty
            ? SliverGrid.builder(
                gridDelegate: gridDelegate,
                itemBuilder: (context, index) {
                  return VideoCardH(
                    videoItem: response[index],
                    onTap: () {
                      _openRelatedVideo(response[index]);
                    },
                    onRemove: () => _relatedController.loadingState
                      ..value.data!.removeAt(index)
                      ..refresh(),
                  );
                },
                itemCount: response.length,
              )
            : const SliverToBoxAdapter(),
      Error(:final errMsg) => HttpError(
        errMsg: errMsg,
        onReload: _relatedController.onReload,
      ),
    };
  }
}
