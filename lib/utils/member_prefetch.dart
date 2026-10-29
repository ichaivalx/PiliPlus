import 'package:PiliPlus/pages/member/space_prefetch.dart';
import 'package:PiliPlus/services/mini_player/mini_player_session.dart';

/// 用户的关注关系、拉黑、资料等变更的统一入口：作废空间页与小窗中预先获取
/// 的该用户数据，仍在持有的在后台重新获取
abstract final class MemberPrefetch {
  static void invalidate(Object? mid) {
    MemberSpacePrefetch.invalidate(mid);
    miniPlayerSession.invalidateMember(mid);
  }

  /// 切换账号后与账号相关的预取都不再准确
  static void invalidateAll() {
    MemberSpacePrefetch.invalidateAll();
    miniPlayerSession.invalidateAccount();
  }
}
