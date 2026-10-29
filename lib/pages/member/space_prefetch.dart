import 'dart:async' show FutureOr, StreamSubscription;

import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/member.dart';
import 'package:PiliPlus/models_new/space/space/data.dart';
import 'package:PiliPlus/services/mini_player/mini_player_session.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

/// UP 主空间页数据的预取：视频详情页（UP 主与合作成员）和 UP 主面板持有
/// 相应的 mid，持有期间始终备好一份，进入空间页时交给 `MemberController`，
/// 首帧即为实际内容；被取用或作废后，仍有持有者时重新预取
///
/// 请求参数对应 `MemberController.customGetData`。`from_view_aid` 不影响
/// 空间页读取的字段（与不带时的响应只有图片地址等随机差异），各入口共用
/// 不带它的结果
abstract final class MemberSpacePrefetch {
  /// 持有者及其持有的 mid
  static final Map<Object, Set<int>> _holders = {};
  static final Map<int, _Prefetch> _entries = {};

  static bool _isHeld(int mid) => _holders.values.any((e) => e.contains(mid));

  /// [owner] 改为持有 [mids]，不再持有的 mid 无人持有时丢弃
  static void hold(Object owner, Iterable<Object?> mids) {
    final next = mids.whereType<int>().toSet();
    final prev = _holders.remove(owner) ?? const <int>{};
    if (next.isNotEmpty) {
      _holders[owner] = next;
    }
    for (final mid in prev.difference(next)) {
      if (!_isHeld(mid)) {
        _entries.remove(mid);
      }
    }
    next.difference(prev).forEach(_arm);
  }

  static void release(Object owner) => hold(owner, const []);

  /// 关注关系、资料等变更后，该 mid 的预取不再准确
  static void invalidate(Object? mid) {
    if (mid is int) {
      _entries.remove(mid);
      _arm(mid);
    }
  }

  /// 取用 [mid] 的预取：已成功时返回结果，可同步应用；仍在请求时返回同一
  /// 请求，失败时重新请求；没有可用的预取或已失败时返回 null
  static FutureOr<LoadingState<SpaceData>>? take(
    int mid,
    Object? fromViewAid,
  ) {
    final prefetch = _entries.remove(mid);
    if (prefetch == null) {
      return null;
    }
    _arm(mid);
    return switch (prefetch.result) {
      final Success<SpaceData> result => result,
      null => prefetch.request.then<LoadingState<SpaceData>>(
        (res) async => res.isSuccess
            ? res
            : await MemberHttp.space(mid: mid, fromViewAid: fromViewAid),
      ),
      _ => null,
    };
  }

  /// 仍有持有者时预取；在页面转场与小窗展开结束后开始，响应的解析不落在
  /// 动画中
  static void _arm(int mid) => _whenSettled(() {
    if (_isHeld(mid) && !_entries.containsKey(mid)) {
      _entries[mid] = _Prefetch(mid);
    }
  });

  static void _whenSettled(VoidCallback callback) {
    final route = Get.routing.route;
    // ignore: invalid_use_of_protected_member
    final controller = route is TransitionRoute ? route.controller : null;
    if (controller != null && controller.isAnimating) {
      void onStatus(AnimationStatus status) {
        if (!status.isAnimating) {
          controller.removeStatusListener(onStatus);
          _whenSettled(callback);
        }
      }

      controller.addStatusListener(onStatus);
    } else if (miniPlayerSession.restoring.value) {
      late final StreamSubscription<bool> subscription;
      subscription = miniPlayerSession.restoring.listen((restoring) {
        if (!restoring) {
          subscription.cancel();
          _whenSettled(callback);
        }
      });
    } else {
      callback();
    }
  }
}

class _Prefetch {
  _Prefetch(int mid) : request = MemberHttp.space(mid: mid) {
    request.then((res) => result = res);
  }

  final Future<LoadingState<SpaceData>> request;
  LoadingState<SpaceData>? result;
}
