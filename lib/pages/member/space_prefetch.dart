import 'dart:async' show FutureOr;

import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/member.dart';
import 'package:PiliPlus/models_new/space/space/data.dart';

/// UP 主空间页数据的预取：视频详情页的 UP 主面板打开时开始请求，从面板
/// 进入空间页时交给 `MemberController`，空间页首帧即为实际内容
///
/// 请求参数对应 `MemberController.customGetData`，面板进入时不带
/// `from_view_aid`；只保留一份，取用、面板关闭或关注关系变更后作废
abstract final class MemberSpacePrefetch {
  static _Prefetch? _current;

  /// 开始预取，返回值用于面板关闭时作废
  static Object? start(int? mid) {
    if (mid == null) {
      return null;
    }
    return _current = _Prefetch(mid);
  }

  /// 作废 [token] 对应且尚未取用的预取
  static void discard(Object? token) {
    if (identical(_current, token)) {
      _current = null;
    }
  }

  /// 关注关系变更后，该 UP 主的预取不再准确
  static void discardMid(Object? mid) {
    if (_current?.mid == mid) {
      _current = null;
    }
  }

  /// 取用 [mid] 的预取：已成功时返回结果，可同步应用；仍在请求时返回同一
  /// 请求，失败时重新请求；没有可用的预取或已失败时返回 null
  static FutureOr<LoadingState<SpaceData>>? take(
    int mid,
    Object? fromViewAid,
  ) {
    final prefetch = _current;
    if (prefetch == null || prefetch.mid != mid || fromViewAid != null) {
      return null;
    }
    _current = null;
    return switch (prefetch.result) {
      final Success<SpaceData> result => result,
      null => prefetch.request.then<LoadingState<SpaceData>>(
        (res) async =>
            res.isSuccess ? res : await MemberHttp.space(mid: mid),
      ),
      _ => null,
    };
  }
}

class _Prefetch {
  _Prefetch(this.mid) : request = MemberHttp.space(mid: mid) {
    request.then((res) => result = res);
  }

  final int mid;
  final Future<LoadingState<SpaceData>> request;
  LoadingState<SpaceData>? result;
}
