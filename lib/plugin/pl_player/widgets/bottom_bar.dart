import 'dart:math' show max;

import 'package:PiliPlus/common/widgets/disabled_icon.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/widgets/common_btn.dart';
import 'package:PiliPlus/services/linked_playback/linked_playback.dart';
import 'package:PiliPlus/services/shutdown_timer_service.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// 视频播放器底栏：左侧控件 | 定时关闭（占满剩余宽度） | 临时单个循环；开启联动
/// 播放时定时关闭改为固定宽度，其左侧为同步播放
class PlayerBottomBar extends StatelessWidget {
  const PlayerBottomBar({
    super.key,
    required this.controller,
    required this.isFullScreen,
    required this.children,
  });

  static const double _loopWidth = 64;
  static const double _syncWidth = 44;
  static const double _timerMinWidth = 76;
  static const double _height = 34;

  final PlPlayerController controller;
  final bool isFullScreen;
  final List<Widget> children;

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


  /// 联动播放的同步开关，未连接时点击立即重连
  Widget get _syncButton => Obx(() {
    final on = linkedPlayback.syncOn.value;
    final connected = linkedPlayback.isConnected;
    return ComBtn(
      width: _syncWidth,
      height: _height,
      tooltip: on
          ? connected
                ? '关闭同步播放'
                : '同步播放（未连接，点击重连）'
          : '开启同步播放',
      icon: Center(
        child: DisabledIcon(
          disable: !on,
          iconSize: 22,
          color: Colors.white,
          child: Icon(
            Icons.sync_rounded,
            size: 22,
            color: on && !connected
                ? Colors.white.withValues(alpha: 0.5)
                : Colors.white,
          ),
        ),
      ),
      onTap: () {
        // 同步已开启但未连接：只重连，不改动同步开关
        if (on && !connected) {
          linkedPlayback.wake();
        } else {
          linkedPlayback
            ..toggleSync()
            ..wake();
        }
      },
    );
  });

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
        final showSync = linkedPlayback.enabled.value && !controller.isLive;
        return Row(
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: max(
                  0,
                  constraints.maxWidth -
                      _loopWidth -
                      _timerMinWidth -
                      (showSync ? _syncWidth : 0),
                ),
              ),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Row(mainAxisSize: MainAxisSize.min, children: children),
              ),
            ),
            if (showSync) ...[
              const Spacer(),
              _syncButton,
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
