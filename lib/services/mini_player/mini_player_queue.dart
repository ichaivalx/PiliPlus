import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/user.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models/common/video/source_type.dart';
import 'package:PiliPlus/models_new/media_list/media_list.dart';
import 'package:PiliPlus/models_new/video/video_detail/data.dart';
import 'package:PiliPlus/models_new/video/video_detail/episode.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_repeat.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';

/// 播完后的下一步
sealed class MiniPlayerNext {
  const MiniPlayerNext();
}

/// 重播当前视频
final class MiniPlayerReplay extends MiniPlayerNext {
  const MiniPlayerReplay();
}

/// 切换视频，[inList] 为 false 时脱离当前列表（相关视频）
final class MiniPlayerSwitch extends MiniPlayerNext {
  const MiniPlayerSwitch(this.item, {required this.inList});

  final BaseEpisodeItem item;
  final bool inList;
}

/// 小窗沿用详情页播放顺序所需的列表：分P、合集、播放全部
///
/// 数据与顺序对应上游 `UgcIntroController.videoDetail`（含倒序后的分P与合集）
/// 和 `VideoDetailController.mediaList`，合并上游时需同步检查
class MiniPlayerQueue {
  /// 详情页交出播放时的列表，[detail] 不属于 [bvid] 时重新获取
  MiniPlayerQueue.snapshot({
    required String bvid,
    required VideoDetailData detail,
    List<MediaListItemModel>? mediaList,
    required Map<String, dynamic> args,
  }) : _bvid = bvid,
       _mediaList = isPlayAll(args) ? mediaList ?? [] : null,
       _listArgs = args {
    if (detail.bvid == bvid) {
      _detail = detail;
    } else {
      _detailLoading = _loadDetail(bvid);
    }
    if (_mediaList?.isEmpty ?? false) {
      _mediaLoading = _loadMedia();
    }
  }

  /// 小窗内切换视频时，按详情页相同的请求获取，与开始播放并行
  MiniPlayerQueue.fetch(Map<String, dynamic> args)
    : _bvid = args['bvid'],
      _mediaList = isPlayAll(args) ? [] : null,
      _listArgs = args {
    _detailLoading = _loadDetail(_bvid);
    if (_mediaList != null) {
      _mediaLoading = _loadMedia();
    }
  }

  /// 对应上游 `VideoDetailController.isPlayAll`
  static bool isPlayAll(Map args) {
    final sourceType = args['sourceType'];
    return sourceType is SourceType &&
        sourceType != SourceType.normal &&
        sourceType != SourceType.file;
  }

  /// 当前播放的视频
  String _bvid;
  VideoDetailData? _detail;
  final List<MediaListItemModel>? _mediaList;

  /// 定义播放全部列表的参数
  final Map<String, dynamic> _listArgs;
  bool _mediaEnd = false;
  Future<void>? _detailLoading;
  Future<bool>? _mediaLoading;

  /// 切换到列表中的另一个视频后获取其分P与合集
  void select(String bvid) {
    if (bvid != _bvid) {
      _bvid = bvid;
      _detailLoading = _loadDetail(bvid);
    }
  }

  /// 对应上游 `UgcIntroController.queryVideoIntro` 中保留倒序合集的处理
  Future<void> _loadDetail(String bvid) async {
    final res = await VideoHttp.videoIntro(bvid: bvid);
    if (bvid != _bvid) {
      return;
    }
    if (res case Success(:final response)) {
      final current = _detail;
      if (current != null && current.ugcSeason?.id == response.ugcSeason?.id) {
        response.ugcSeason = current.ugcSeason;
      }
      _detail = response;
    }
  }

  /// 对应上游 `VideoDetailController.getMediaList` 向后加载一页
  Future<bool> _loadMedia() async {
    final list = _mediaList!;
    final args = _listArgs;
    final count = args['count'];
    if (_mediaEnd || (count != null && list.length >= count)) {
      return false;
    }
    final res = await UserHttp.getMediaList(
      type: args['mediaType'] ?? (args['sourceType'] as SourceType).mediaType,
      bizId: args['mediaId'] ?? -1,
      ps: 20,
      oid: list.isEmpty
          ? args['isContinuePlaying'] == true
                ? args['oid']
                : null
          : list.last.aid,
      otype: list.lastOrNull?.type,
      desc: args['desc'] ?? false,
      sortField: args['sortField'] ?? 1,
      withCurrent: list.isEmpty && args['isContinuePlaying'] == true,
    );
    if (res case Success(:final response)) {
      if (response.mediaList.isEmpty) {
        _mediaEnd = true;
        return false;
      }
      list.addAll(response.mediaList);
      return true;
    }
    res.toast();
    return false;
  }

  /// 对应上游 `UgcIntroController.nextPlay`：分P → 播放全部 → 合集，
  /// 播放全部的列表到末尾时先加载下一页，返回 null 表示停止
  Future<MiniPlayerNext?> next({
    required int cid,
    required PlayRepeat repeat,
    required bool showRelated,
  }) async {
    await _detailLoading;
    await _mediaLoading;
    return _next(cid, repeat, showRelated, false);
  }

  Future<MiniPlayerNext?> _next(
    int cid,
    PlayRepeat repeat,
    bool showRelated,
    bool skipPart,
  ) async {
    final detail = _detail;
    final pages = detail?.bvid == _bvid ? detail!.pages : null;
    final season = detail?.ugcSeason;
    final mediaList = _mediaList;

    final List<BaseEpisodeItem> episodes;
    var isPart = false;
    if (!skipPart && pages != null && pages.length > 1) {
      isPart = true;
      episodes = pages;
    } else if (mediaList != null) {
      episodes = mediaList;
    } else if (season?.sections case final sections?) {
      episodes = [for (final section in sections) ...?section.episodes];
    } else {
      episodes = const [];
    }

    if (episodes.isEmpty) {
      if (repeat == PlayRepeat.listCycle) {
        return const MiniPlayerReplay();
      }
      if (repeat == PlayRepeat.autoPlayRelated && showRelated) {
        return _related();
      }
      return null;
    }

    final currentCid = skipPart
        ? detail!.isPageReversed
              ? pages!.last.cid
              : pages!.first.cid
        : cid;
    final currentIndex = episodes.indexWhere((e) => e.cid == currentCid);
    var nextIndex = currentIndex + 1;

    if (nextIndex >= episodes.length && !isPart && mediaList != null) {
      await (_mediaLoading = _loadMedia());
    }

    if (nextIndex >= episodes.length) {
      if (isPart && (mediaList != null || season != null)) {
        return _next(cid, repeat, showRelated, true);
      }
      if (repeat == PlayRepeat.listCycle) {
        nextIndex = 0;
      } else if (repeat == PlayRepeat.autoPlayRelated && showRelated) {
        return _related();
      } else {
        return null;
      }
    }

    var nextCid = episodes[nextIndex].cid;
    while (nextCid == null) {
      if (++nextIndex >= episodes.length) {
        return null;
      }
      nextCid = episodes[nextIndex].cid;
    }
    if (nextCid == cid) {
      return null;
    }
    return MiniPlayerSwitch(episodes[nextIndex], inList: true);
  }

  /// 对应上游 `UgcIntroController.playRelated`
  Future<MiniPlayerNext?> _related() async {
    final res = await VideoHttp.relatedVideoList(bvid: _bvid);
    if (res case Success(:final response)) {
      final item = response?.firstOrNull;
      if (item == null) {
        SmartDialog.showToast('暂无相关视频，停止连播');
        return null;
      }
      return MiniPlayerSwitch(
        BaseEpisodeItem(
          aid: item.aid,
          bvid: item.bvid,
          cid: item.cid,
          cover: item.cover,
          title: item.title,
        ),
        inList: false,
      );
    }
    res.toast();
    return null;
  }
}
