import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/user.dart';
import 'package:PiliPlus/models_new/space_setting/data.dart';
import 'package:PiliPlus/models_new/space_setting/privacy.dart';
import 'package:PiliPlus/pages/common/common_data_controller.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/member_prefetch.dart';

class SpaceSettingController
    extends CommonDataController<SpaceSettingData, Privacy?> {
  @override
  void onInit() {
    super.onInit();
    queryData();
  }

  bool? hasMod;

  @override
  bool customHandleResponse(
    bool isRefresh,
    Success<SpaceSettingData> response,
  ) {
    loadingState.value = Success(response.response.privacy);
    return true;
  }

  @override
  Future<LoadingState<SpaceSettingData>> customGetData() =>
      UserHttp.spaceSetting();

  Future<void> onMod() async {
    if (hasMod ?? false) {
      if (loadingState.value case Success(:final response?)) {
        // 预取的自己的空间页数据含这些设置；变更完成后再次作废
        final mid = Accounts.main.mid;
        MemberPrefetch.invalidate(mid);
        final res = await UserHttp.spaceSettingMod(
          {
            for (final e in response.list1) e.key: e.value,
            for (final e in response.list2) e.key: e.value,
            for (final e in response.list3) e.key: e.value,
          },
        );
        MemberPrefetch.invalidate(mid);
        if (!res.isSuccess) {
          res.toast();
        }
      }
    }
  }
}
