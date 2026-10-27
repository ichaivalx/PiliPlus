import 'dart:math' show max;

import 'package:PiliPlus/common/widgets/disabled_icon.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/widgets/common_btn.dart';
import 'package:PiliPlus/services/shutdown_timer_service.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// 视频播放器底栏：左侧控件 | 定时关闭（占满剩余宽度） | 临时单个循环
class PlayerBottomBar extends StatelessWidget {
  const PlayerBottomBar({
    super.key,
    required this.controller,
    required this.isFullScreen,
    required this.children,
  });

  static const double _loopWidth = 64;
  static const double _height = 34;

  final PlPlayerController controller;
  final bool isFullScreen;
  final List<Widget> children;

  Widget _timerButton(BuildContext context) => ShutdownPanel(
    buildCountdownText: (text) {
      final waiting = shutdownTimerService.isWaiting;
      final active = waiting || text != null;
      return ComBtn(
        width: double.infinity,
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
                  active ? Icons.timer : Icons.timer_outlined,
                  size: 18,
                  color: Colors.white,
                ),
                Text(
                  waiting ? '播完停止' : text ?? '定时关闭',
                  maxLines: 1,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
              ],
            ),
          ),
        ),
      );
    },
    builder: (_, countdown, _, _) => countdown,
  );

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
      builder: (context, constraints) => Row(
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: max(0, constraints.maxWidth - _loopWidth),
            ),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Row(mainAxisSize: MainAxisSize.min, children: children),
            ),
          ),
          Expanded(child: _timerButton(context)),
          _loopButton,
        ],
      ),
    );
  }
}
