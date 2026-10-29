import 'package:PiliPlus/common/widgets/dialog/dialog.dart';
import 'package:PiliPlus/http/black.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models_new/blacklist/data.dart';
import 'package:PiliPlus/models_new/blacklist/list.dart';
import 'package:PiliPlus/pages/common/common_list_controller.dart';
import 'package:PiliPlus/pages/member/space_prefetch.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/extension/num_ext.dart';
import 'package:PiliPlus/utils/global_data.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:material_ui/material_ui.dart';

class BlackListController
    extends CommonListController<BlackListData, BlackListItem> {
  int? _total;
  final blackMids = GlobalData().blackMids;

  @override
  void onInit() {
    super.onInit();
    if (Accounts.main.isLogin) {
      queryData();
    } else {
      loadingState.value = const Error('账号未登录');
    }
  }

  @override
  List<BlackListItem>? getDataList(BlackListData response) {
    _total = response.total;
    return response.list;
  }

  @override
  void checkIsEnd(int length) {
    if (_total != null && length >= _total!) {
      isEnd = true;
    }
  }

  Future<bool> onRemove(BuildContext context, int index, name, mid) async {
    final confirm = await showConfirmDialog(
      context: context,
      title: Text('确定将 $name 移出黑名单？'),
    );
    if (confirm) {
      // 预取的空间页数据含拉黑状态；变更完成后再次作废
      MemberSpacePrefetch.invalidate(mid);
      final result = await VideoHttp.relationMod(mid: mid, act: 6, reSrc: 11);
      MemberSpacePrefetch.invalidate(mid);
      if (result.isSuccess) {
        loadingState
          ..value.data!.removeAt(index)
          ..refresh();
        _total -= 1;
        SmartDialog.showToast('移除成功');
        return true;
      }
    }
    return false;
  }

  @override
  Future<LoadingState<BlackListData>> customGetData() =>
      BlackHttp.blackList(pn: page);

  @override
  void onClose() {
    super.onClose();
    if (loadingState.value case Success(:final response?)) {
      blackMids.addAll(response.map((e) => e.mid!));
    }
    Pref.blackMids = blackMids;
  }
}
