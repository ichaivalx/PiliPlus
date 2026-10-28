import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/user.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models/common/video/source_type.dart';
import 'package:PiliPlus/models/common/video/video_type.dart';
import 'package:PiliPlus/models_new/media_list/media_list.dart';
import 'package:PiliPlus/models_new/video/video_detail/data.dart';
import 'package:PiliPlus/models_new/video/video_detail/episode.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_repeat.dart';
import 'package:PiliPlus/utils/id_utils.dart';
import 'package:PiliPlus/utils/reply_scheme_helper.dart';
import 'package:PiliPlus/utils/utils.dart';
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
  const MiniPlayerSwitch(this.args, {required this.inList});

  /// 与 `PageUtils.toVideoPage` 一样的完整参数，可直接用于打开详情页
  final Map<String, dynamic> args;
  final bool inList;
}

enum _PageResult { loaded, end, failed }

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
  Future<_PageResult>? _mediaLoading;

  /// 切换到列表中的另一个视频后获取其分P与合集
  void select(String bvid) {
    if (bvid != _bvid) {
      _bvid = bvid;
      _detailLoading = _loadDetail(bvid);
    }
  }

  /// 对应上游 `UgcIntroController.queryVideoIntro` 中保留倒序合集的处理
  Future<void> _loadDetail(String bvid, {bool reportError = false}) async {
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
    } else if (reportError) {
      res.toast();
    }
  }

  /// 对应上游 `VideoDetailController.getMediaList` 向后加载一页，
  /// 失败时列表不变，下次仍从同一位置加载
  Future<_PageResult> _loadMedia() async {
    final list = _mediaList!;
    final args = _listArgs;
    final count = args['count'];
    if (_mediaEnd || (count != null && list.length >= count)) {
      return _PageResult.end;
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
        return _PageResult.end;
      }
      list.addAll(response.mediaList);
      return _PageResult.loaded;
    }
    res.toast();
    return _PageResult.failed;
  }

  /// 对应上游 `UgcIntroController.nextPlay`：分P → 播放全部 → 合集，
  /// 播放全部的列表到末尾时先加载下一页，返回 null 表示停止
  ///
  /// 详情或列表获取失败时重试一次，仍失败则停止，避免误判为没有列表
  Future<MiniPlayerNext?> next(
    Map<String, dynamic> current, {
    required PlayRepeat repeat,
    required bool showRelated,
  }) async {
    await _detailLoading;
    if (_detail?.bvid != _bvid) {
      await (_detailLoading = _loadDetail(_bvid, reportError: true));
      if (_detail?.bvid != _bvid) {
        return null;
      }
    }
    if (await _mediaLoading == _PageResult.failed &&
        await (_mediaLoading = _loadMedia()) == _PageResult.failed) {
      return null;
    }
    return _next(current, repeat, showRelated, false);
  }

  Future<MiniPlayerNext?> _next(
    Map<String, dynamic> current,
    PlayRepeat repeat,
    bool showRelated,
    bool skipPart,
  ) async {
    final cid = current['cid'] as int;
    final detail = _detail!;
    final season = detail.ugcSeason;
    final mediaList = _mediaList;

    final List<BaseEpisodeItem> episodes;
    var isPart = false;
    if (!skipPart && detail.hasParts) {
      isPart = true;
      episodes = detail.pages!;
    } else if (mediaList != null) {
      // 直接引用列表，加载下一页后的新增项随之可见
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
        return _related(current);
      }
      return null;
    }

    final currentCid = skipPart
        ? detail.isPageReversed
              ? detail.pages!.last.cid
              : detail.pages!.first.cid
        : cid;
    final currentIndex = episodes.indexWhere((e) => e.cid == currentCid);
    var nextIndex = currentIndex + 1;

    if (nextIndex >= episodes.length &&
        !isPart &&
        mediaList != null &&
        await (_mediaLoading = _loadMedia()) == _PageResult.failed) {
      return null;
    }

    if (nextIndex >= episodes.length) {
      if (isPart && (mediaList != null || season != null)) {
        return _next(current, repeat, showRelated, true);
      }
      if (repeat == PlayRepeat.listCycle) {
        nextIndex = 0;
      } else if (repeat == PlayRepeat.autoPlayRelated && showRelated) {
        return _related(current);
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
    return MiniPlayerSwitch(
      _argsFor(current, episodes[nextIndex], inList: true),
      inList: true,
    );
  }

  /// 对应上游 `UgcIntroController.playRelated`
  Future<MiniPlayerNext?> _related(Map<String, dynamic> current) async {
    final res = await VideoHttp.relatedVideoList(bvid: _bvid);
    if (res case Success(:final response)) {
      final item = response?.firstOrNull;
      if (item == null) {
        SmartDialog.showToast('暂无相关视频，停止连播');
        return null;
      }
      if (item.cid == null) {
        return null;
      }
      return MiniPlayerSwitch(
        _argsFor(
          current,
          BaseEpisodeItem(
            aid: item.aid,
            bvid: item.bvid,
            cid: item.cid,
            cover: item.cover,
            title: item.title,
          ),
          inList: false,
        ),
        inList: false,
      );
    }
    res.toast();
    return null;
  }

  /// 列表内的下一项沿用当前列表参数，恢复时详情页以同一列表模式打开
  static Map<String, dynamic> _argsFor(
    Map<String, dynamic> current,
    BaseEpisodeItem item, {
    required bool inList,
  }) {
    final bvid = item.bvid ?? current['bvid'] as String;
    final aid = item.aid ?? IdUtils.bv2av(bvid);
    final cid = item.cid!;
    final sameVideo = bvid == current['bvid'];
    return {
      if (inList) ...current,
      'aid': aid,
      'bvid': bvid,
      'cid': cid,
      'videoType': VideoType.ugc,
      'heroTag': Utils.makeHeroTag(cid),
      'title': sameVideo ? current['title'] : item.title,
      'cover': sameVideo ? current['cover'] : item.cover,
      if (inList && isPlayAll(current)) ...{
        'oid': aid,
        'isContinuePlaying': true,
      },
    }
      ..remove('progress')
      ..remove('isVertical')
      ..remove(rootRpIdKey)
      ..remove(secondRpIdKey);
  }
}
