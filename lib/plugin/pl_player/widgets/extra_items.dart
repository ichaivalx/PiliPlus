import 'package:PiliPlus/common/widgets/custom_icon.dart';
import 'package:PiliPlus/common/widgets/disabled_icon.dart';
import 'package:PiliPlus/pages/video/controller.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/bottom_control_type.dart';
import 'package:PiliPlus/plugin/pl_player/widgets/common_btn.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:collection/collection.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// 视频播放器的倍速、高能进度条、分段信息、翻译、字幕按钮：通常在底栏左侧，底栏
/// 显示联动控件时移到顶部栏
class PlayerExtraItem extends StatelessWidget {
  const PlayerExtraItem({
    super.key,
    required this.type,
    required this.player,
    required this.videoDetail,
    required this.width,
    required this.height,
    this.showViewPoints,
  });

  /// 播放器 [player] 显示的这类按钮，按从左到右的顺序
  static List<BottomControlType> typesFor(PlPlayerController player) {
    final isNotFileSource = !player.isFileSource;
    return [
      .speed,
      if (isNotFileSource && player.showDmChart) .dmChart,
      if (isNotFileSource && player.showViewPoints) .viewPoints,
      if (isNotFileSource) .aiTranslate,
      .subtitle,
    ];
  }

  final BottomControlType type;
  final PlPlayerController player;
  final VideoDetailController videoDetail;

  /// 图标按钮的尺寸；倍速按文字宽度
  final double width;
  final double height;
  final VoidCallback? showViewPoints;

  @override
  Widget build(BuildContext context) => switch (type) {
    /// 播放速度
    BottomControlType.speed => Obx(
      () => PopupMenuButton<double>(
        tooltip: '倍速',
        requestFocus: false,
        initialValue: player.playbackSpeed,
        color: Colors.black.withValues(alpha: 0.8),
        itemBuilder: (context) {
          return player.speedList
              .map(
                (double speed) => PopupMenuItem<double>(
                  height: 35,
                  padding: const EdgeInsets.only(left: 30),
                  value: speed,
                  onTap: () => player.setPlaybackSpeed(speed),
                  child: Text(
                    "${speed}X",
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                    semanticsLabel: "$speed倍速",
                  ),
                ),
              )
              .toList();
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text(
            "${player.playbackSpeed}X",
            style: const TextStyle(color: Colors.white, fontSize: 13),
            semanticsLabel: "${player.playbackSpeed}倍速",
          ),
        ),
      ),
    ),

    /// 高能进度条
    BottomControlType.dmChart => Obx(
      () {
        final list = videoDetail.dmTrend.value?.dataOrNull;
        if (list != null && list.isNotEmpty) {
          final show = videoDetail.showDmTrendChart.value;
          return ComBtn(
            width: width,
            height: height,
            tooltip: '高能进度条',
            icon: DisabledIcon(
              disable: !show,
              child: const Icon(
                Icons.show_chart,
                size: 22,
                color: Colors.white,
              ),
            ),
            onTap: () => videoDetail.showDmTrendChart.value = !show,
          );
        }
        return const SizedBox.shrink();
      },
    ),

    /// 分段信息
    BottomControlType.viewPoints => Obx(
      () {
        if (videoDetail.viewPointList.isNotEmpty) {
          return ComBtn(
            width: width,
            height: height,
            tooltip: '分段信息',
            icon: DisabledIcon(
              disable: !videoDetail.showVP.value,
              child: const Icon(
                CustomIcons.view_headline_rotate_90,
                size: 22,
                color: Colors.white,
              ),
            ),
            onTap: showViewPoints,
            onLongPress: () {
              Feedback.forLongPress(context);
              videoDetail.showVP.toggle();
            },
            onSecondaryTap: PlatformUtils.isMobile
                ? null
                : () => videoDetail.showVP.toggle(),
          );
        }
        return const SizedBox.shrink();
      },
    ),

    /// 翻译
    BottomControlType.aiTranslate => Obx(
      () {
        final list = videoDetail.languages.value;
        if (list != null && list.isNotEmpty) {
          return PopupMenuButton<String>(
            tooltip: '翻译',
            requestFocus: false,
            initialValue: videoDetail.currLang.value,
            onSelected: videoDetail.setLanguage,
            color: Colors.black.withValues(alpha: 0.8),
            itemBuilder: (context) => [
              const PopupMenuItem<String>(
                height: 35,
                value: '',
                child: Text(
                  "关闭翻译",
                  style: TextStyle(color: Colors.white, fontSize: 13),
                ),
              ),
              ...list.map(
                (e) => PopupMenuItem<String>(
                  height: 35,
                  value: e.lang,
                  child: Text(
                    e.title!,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ),
              ),
            ],
            child: SizedBox(
              width: width,
              height: height,
              child: const Icon(
                Icons.translate,
                size: 18,
                color: Colors.white,
              ),
            ),
          );
        }
        return const SizedBox.shrink();
      },
    ),

    /// 字幕
    BottomControlType.subtitle => Obx(
      () {
        if (videoDetail.subtitles.isNotEmpty) {
          final val = videoDetail.vttSubtitlesIndex.value;
          return PopupMenuButton<int>(
            tooltip: '字幕',
            requestFocus: false,
            initialValue: val,
            color: Colors.black.withValues(alpha: 0.8),
            itemBuilder: (context) {
              return [
                PopupMenuItem<int>(
                  value: 0,
                  height: 35,
                  onTap: () => videoDetail.setSubtitle(0),
                  child: const Text(
                    "关闭字幕",
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                    ),
                  ),
                ),
                ...videoDetail.subtitles.mapIndexed((i, e) {
                  return PopupMenuItem<int>(
                    value: i + 1,
                    height: 35,
                    onTap: () => videoDetail.setSubtitle(i + 1),
                    child: Text(
                      e.lanDoc ?? e.lan,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const .new(color: Colors.white, fontSize: 13),
                    ),
                  );
                }),
              ];
            },
            child: SizedBox(
              width: width,
              height: height,
              child: val == 0
                  ? const Icon(
                      Icons.closed_caption_off_outlined,
                      size: 22,
                      color: Colors.white,
                    )
                  : const Icon(
                      Icons.closed_caption_off_rounded,
                      size: 22,
                      color: Colors.white,
                    ),
            ),
          );
        }
        return const SizedBox.shrink();
      },
    ),

    _ => const SizedBox.shrink(),
  };
}
