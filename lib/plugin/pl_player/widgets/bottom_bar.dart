import 'dart:math' show max;

import 'package:PiliPlus/common/widgets/disabled_icon.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/widgets/common_btn.dart';
import 'package:PiliPlus/services/linked_playback/linked_bar.dart';
import 'package:PiliPlus/services/shutdown_timer_service.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// 视频播放器底栏：左侧控件 | 定时关闭（占满剩余宽度） | 临时单个循环；显示联动
/// 控件时左侧只留 [leading]（[extra] 移到顶部栏），定时关闭改为固定宽度，其左侧
/// 的剩余宽度为联动控件
class PlayerBottomBar extends StatelessWidget {
  const PlayerBottomBar({
    super.key,
    required this.controller,
    required this.isFullScreen,
    required this.leading,
    required this.extra,
  });

  static const double _loopWidth = 64;
  static const double _timerMinWidth = 76;
  static const double _height = 34;

  final PlPlayerController controller;
  final bool isFullScreen;

  /// 播放暂停与时间
  final List<Widget> leading;

  /// 倍速、字幕等，显示联动控件时不在底栏
  final List<Widget> extra;

  Widget _timerButton(BuildContext context, {required double width}) {
    return ShutdownPanel(
      buildCountdownText: (text) {
        return ComBtn(
          width: width,
          height: _height,
          tooltip: '定时关闭',
          onTap: () => shutdownTimerService.showScheduleExitDialog(
            context,
            isFullScreen: isFullScreen,
          ),
          icon: Align(
            alignment: Alignment.centerRight,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(
                spacing: 4,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    text != null ? Icons.timer : Icons.timer_outlined,
                    size: 18,
                    color: Colors.white,
                  ),
                  Text(
                    shutdownTimerService.isWaiting
                        ? '播完停止'
                        : text ?? '定时关闭',
                    maxLines: 1,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }


  Widget get _loopButton => Obx(() {
    final enabled = controller.isSingleCycle;
    return ComBtn(
      width: _loopWidth,
      height: _height,
      tooltip: enabled ? '关闭单个循环' : '开启单个循环',
      icon: Center(
        child: DisabledIcon(
          disable: !enabled,
          iconSize: 22,
          color: Colors.white,
          child: const Icon(
            Icons.repeat_one_rounded,
            size: 22,
            color: Colors.white,
          ),
        ),
      ),
      onTap: controller.toggleTemporarySingleCycle,
    );
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => Obx(() {
        final showLinked = LinkedBarControls.showsFor(controller);
        return Row(
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: max(
                  0,
                  constraints.maxWidth -
                      _loopWidth -
                      _timerMinWidth -
                      (showLinked ? LinkedBarControls.minWidth : 0),
                ),
              ),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: showLinked ? leading : [...leading, ...extra],
                ),
              ),
            ),
            if (showLinked) ...[
              // 左侧控件之外的剩余宽度
              Expanded(
                child: LinkedBarControls(
                  controller: controller,
                  onInteraction: () => controller.controls = true,
                ),
              ),
              _timerButton(context, width: _timerMinWidth),
            ] else
              Expanded(
                child: _timerButton(context, width: double.infinity),
              ),
            _loopButton,
          ],
        );
      }),
    );
  }
}
