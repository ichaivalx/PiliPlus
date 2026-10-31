// 定时关闭服务

import 'dart:async' show StreamSubscription, Timer;

import 'package:PiliPlus/models/common/enum_with_label.dart';
import 'package:PiliPlus/pages/video/introduction/ugc/widgets/menu_row.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/utils/device_utils.dart';
import 'package:PiliPlus/utils/duration_utils.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/theme_utils.dart';
import 'package:collection/collection.dart';
import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoPicker;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get_rx/src/rx_types/rx_types.dart';
import 'package:get/get_state_manager/src/rx_flutter/rx_obx_widget.dart';
import 'package:material_ui/material_ui.dart';

const _kSqueeze = 1.25;
const _kItemExtent = 38.0;

enum _ShutdownType with EnumWithLabel {
  pause('暂停视频'),
  exit('退出APP'),
  ;

  @override
  final String label;
  const _ShutdownType(this.label);
}

final shutdownTimerService = ShutdownTimerService._internal();

/// 独立于视频播放器的播放目标（听音频页）
typedef ShutdownTarget = ({VoidCallback pause, ValueGetter<bool> isPlaying});

/// 一次播放源加载或待恢复的暂停（后台、被打断），之后是否自动播放
final class ShutdownLoad {
  ShutdownLoad._();

  /// 定时关闭到期或停止播放，不可撤销
  bool _blocked = false;

  /// 用户暂停，再次播放时撤销
  bool _held = false;
}

class ShutdownTimerService {
  ShutdownTimerService._internal();

  final List<ShutdownTarget> _targets = [];

  /// 随页面生命周期注册，只注销自己的目标
  void addTarget(ShutdownTarget target) => _targets.add(target);

  void removeTarget(ShutdownTarget target) => _targets.remove(target);

  final List<Future<void> Function(bool exit)> _expiredListeners = [];

  /// 退出应用前等待到期通知完成（如联动播放发出停止消息）的上限
  static const _expiredWait = Duration(seconds: 2);

  /// 定时关闭到期（含播完后停止）时通知，[exit] 为随后退出应用
  void addExpiredListener(Future<void> Function(bool exit) listener) =>
      _expiredListeners.add(listener);

  Future<void> _notifyExpired({bool exit = false}) =>
      Future.wait<void>([
            for (final listener in _expiredListeners.toList()) listener(exit),
          ])
          .timeout(_expiredWait, onTimeout: () => const <void>[])
          .then<void>((_) {}, onError: (_) {});

  /// 通知到期并等待完成后退出应用
  void _exitAfterNotify() {
    _notifyExpired(exit: true).whenComplete(_syncProgressAndExit);
  }

  final Rxn<DateTime> _deadline = Rxn<DateTime>();
  DateTime? get deadline => _deadline.value;
  Timer? _shutdownTimer;
  bool get isActive => deadline != null || isWaiting;
  int _durationInMinutes = 0;
  _ShutdownType _shutdownType = .pause;

  final RxBool _isWaiting = false.obs;
  bool get isWaiting => _isWaiting.value;
  bool _waitUntilCompleted = false;
  final Set<ShutdownLoad> _loads = {};

  void _stopTimer() {
    _deadline.value = null;
    _shutdownTimer?.cancel();
    _shutdownTimer = null;
  }

  void reset([int durationInMinutes = 0]) {
    _stopTimer();
    _isWaiting.value = false;
    _durationInMinutes = durationInMinutes;
  }

  /// [from] 为转交的原加载（原加载随后注销）：沿用其已有的停止、暂缓状态
  ShutdownLoad beginLoad({ShutdownLoad? from}) {
    final load = ShutdownLoad._();
    if (from != null) {
      load
        .._blocked = from._blocked
        .._held = from._held;
    }
    _loads.add(load);
    return load;
  }

  /// 由创建者在加载结束（成功、失败或被取代）时调用
  void endLoad(ShutdownLoad load) => _loads.remove(load);

  bool canAutoplay(ShutdownLoad load) => !load._blocked && !load._held;

  /// 只被暂缓（如音频打断），未被停止播放作废：暂缓解除后可自动播放
  bool isHeld(ShutdownLoad load) => load._held && !load._blocked;

  /// 存在完成后会自动播放的加载
  bool get hasPendingAutoplay => _loads.any(canAutoplay);

  /// 停止播放（如关闭小窗、拔出耳机）时，进行中的加载与待恢复的暂停不再自动播放
  void cancelPendingAutoplay() => _blockLoads();

  /// 用户暂停：进行中的加载完成后保持暂停，直到用户再次播放
  void holdPendingAutoplay() {
    for (final load in _loads) {
      load._held = true;
    }
  }

  void releasePendingAutoplay() {
    for (final load in _loads) {
      load._held = false;
    }
  }

  /// 阻止正在进行的加载自动播放，返回是否存在这样的加载
  bool _blockLoads() {
    for (final load in _loads) {
      load._blocked = true;
    }
    return _loads.isNotEmpty;
  }

  void _startShutdownTimer(int durationInMinutes) {
    reset(durationInMinutes);
    if (durationInMinutes == 0) {
      SmartDialog.showToast('取消定时关闭');
      return;
    }
    SmartDialog.showToast('设置 ${_format(durationInMinutes)} 后定时关闭');
    _deadline.value = DateTime.now().add(Duration(minutes: durationInMinutes));
    _shutdownTimer = Timer(
      Duration(minutes: durationInMinutes),
      _handleShutdown,
    );
  }

  bool get _isPlaying =>
      _targets.any((e) => e.isPlaying()) ||
      (PlPlayerController.instance?.playerStatus.isPlaying ?? false);

  void _pause() {
    for (final target in _targets) {
      if (target.isPlaying()) {
        target.pause();
      }
    }
    PlPlayerController.pauseIfExists();
  }

  void _handleShutdown() {
    _stopTimer();
    final isLive = PlPlayerController.instance?.isLive ?? false;
    final waitUntilCompleted = _waitUntilCompleted && !isLive;
    if (_isPlaying) {
      if (waitUntilCompleted) {
        // 等待当前播放完毕，正在加载的下一项不再自动播放
        _blockLoads();
        _isWaiting.value = true;
        return;
      }
      if (_shutdownType == _ShutdownType.exit) {
        _exitAfterNotify();
        return;
      }
      _notifyExpired();
      _blockLoads();
      _pause();
      SmartDialog.showToast('定时时间已到，已暂停');
    } else {
      if (_shutdownType == _ShutdownType.exit) {
        _exitAfterNotify();
        return;
      }
      _notifyExpired();
      if (_blockLoads()) {
        SmartDialog.showToast('定时时间已到，已暂停');
      }
    }
    _durationInMinutes = 0;
  }

  void handleWaiting() {
    switch (_shutdownType) {
      case .pause:
        _notifyExpired();
        _blockLoads();
        _isWaiting.value = false;
        _durationInMinutes = 0;
        SmartDialog.showToast('定时时间已到，已暂停');
      case .exit:
        _exitAfterNotify();
    }
  }

  void _syncProgressAndExit() {
    if (PlPlayerController.instance case final player?) {
      final res = player.makeHeartBeat(
        player.position.value,
        type: .completed,
        isManual: true,
      );
      if (res != null) {
        res.whenComplete(DeviceUtils.exitApp);
        return;
      }
    }
    DeviceUtils.exitApp();
  }

  static (int hour, int minute) _parseMinutes(int minutes) =>
      (minutes ~/ 60, minutes % 60);

  static String _format(int minutes) {
    if (minutes == 60) return '60分钟';
    final (int hour, int minute) = _parseMinutes(minutes);
    if (hour > 0 && minute > 0) {
      return '$hour小时$minute分钟';
    } else if (hour > 0) {
      return '$hour小时';
    } else {
      return '$minute分钟';
    }
  }

  Widget _pickerBuider(
    int count, {
    required ValueChanged<int> onSelectedItemChanged,
    required FixedExtentScrollController scrollController,
  }) {
    return CupertinoPicker(
      // looping: true,
      squeeze: _kSqueeze,
      itemExtent: _kItemExtent,
      scrollController: scrollController,
      onSelectedItemChanged: onSelectedItemChanged,
      children: List.generate(
        count,
        (index) => Center(
          child: Text(
            index.toString().padLeft(2, '0'),
            style: const TextStyle(fontSize: 20, letterSpacing: .4),
          ),
        ),
      ),
    );
  }

  void _showTimePickerDialog(
    BuildContext context,
    VoidCallback onCountdown,
    StateSetter setState,
  ) {
    final values = _parseMinutes(_durationInMinutes);
    var hour = values.$1;
    var minute = values.$2;

    final hourController = FixedExtentScrollController(initialItem: hour);
    final minuteController = FixedExtentScrollController(initialItem: minute);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        contentPadding: const .fromLTRB(20, 6, 20, 0),
        actionsPadding: const .fromLTRB(20, 0, 20, 16),
        constraints: const .tightFor(width: 320, height: 320),
        content: Row(
          children: [
            Expanded(
              child: _pickerBuider(
                25,
                scrollController: hourController,
                onSelectedItemChanged: (value) => hour = value,
              ),
            ),
            const Text('时'),
            const SizedBox(width: 10),
            Expanded(
              child: _pickerBuider(
                60,
                scrollController: minuteController,
                onSelectedItemChanged: (value) => minute = value,
              ),
            ),
            const Text('分'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(
              '取消',
              style: TextStyle(color: ColorScheme.of(context).outline),
            ),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _startShutdownTimer(hour * 60 + minute);
              onCountdown();
              setState(() {});
            },
            child: const Text('确认'),
          ),
        ],
      ),
    ).whenComplete(() {
      hourController.dispose();
      minuteController.dispose();
    });
  }

  void showScheduleExitDialog(
    BuildContext context, {
    required bool isFullScreen,
    bool isLive = false,
  }) {
    const Set<int> scheduleTimeMinutes = {0, 15, 30, 45, 60};
    const TextStyle titleStyle = TextStyle(fontSize: 14);

    final child = ShutdownPanel(
      builder: (context, countdown, onCountdown, setState) {
        final theme = Theme.of(context);
        return Padding(
          padding: const .all(12),
          child: Material(
            clipBehavior: .hardEdge,
            color: theme.colorScheme.surface,
            borderRadius: const .all(.circular(12)),
            child: ListView(
              padding: const .symmetric(vertical: 14),
              children: [
                Stack(
                  alignment: .center,
                  clipBehavior: .none,
                  children: [
                    const Text('定时关闭', style: titleStyle),
                    Positioned(top: 0, bottom: 0, right: 16, child: countdown),
                  ],
                ),
                const SizedBox(height: 10),
                ...{...scheduleTimeMinutes, _durationInMinutes}
                    .sorted(Comparable.compare)
                    .map(
                      (minutes) => ListTile(
                        dense: true,
                        onTap: () {
                          Navigator.pop(context);
                          _startShutdownTimer(minutes);
                        },
                        title: Text(
                          switch (minutes) {
                            0 => '禁用',
                            _ => _format(minutes),
                          },
                          style: titleStyle,
                        ),
                        trailing: _durationInMinutes == minutes
                            ? Icon(
                                size: 20,
                                Icons.done,
                                color: theme.colorScheme.primary,
                              )
                            : null,
                      ),
                    ),
                ListTile(
                  dense: true,
                  onTap: () =>
                      _showTimePickerDialog(context, onCountdown, setState),
                  title: const Text('自定义', style: titleStyle),
                ),
                if (!isLive) ...[
                  Builder(
                    builder: (context) {
                      void onChanged([_]) {
                        _waitUntilCompleted = !_waitUntilCompleted;
                        (context as Element).markNeedsBuild();
                      }

                      return ListTile(
                        dense: true,
                        onTap: onChanged,
                        title: const Text('额外等待视频播放完毕', style: titleStyle),
                        trailing: Transform.scale(
                          alignment: .centerRight,
                          scale: 0.8,
                          child: Switch(
                            value: _waitUntilCompleted,
                            onChanged: onChanged,
                          ),
                        ),
                      );
                    },
                  ),
                ],
                const SizedBox(height: 5),
                Padding(
                  padding: const .only(left: 18),
                  child: Builder(
                    builder: (context) {
                      return Row(
                        spacing: 12,
                        children: [
                          const Text('倒计时结束:', style: titleStyle),
                          ..._ShutdownType.values.map(
                            (e) => ActionRowLineItem(
                              onTap: () {
                                _shutdownType = e;
                                (context as Element).markNeedsBuild();
                              },
                              text: ' ${e.label} ',
                              selectStatus: _shutdownType == e,
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );

    PageUtils.showVideoBottomSheet(
      context,
      maxWidth: 512,
      child: isLive ? Theme(data: ThemeUtils.darkTheme, child: child) : child,
    );
  }
}

typedef ShutdownStatefulWidgetBuilder = Widget Function(
  BuildContext context,
  Widget countdown,
  VoidCallback onCountdown,
  StateSetter setState,
);

class ShutdownPanel extends StatefulWidget {
  const ShutdownPanel({
    super.key,
    this.builder,
    this.buildCountdownText = _kBuildCountdownText,
  });

  /// 为空时仅显示倒计时
  final ShutdownStatefulWidgetBuilder? builder;
  final Widget Function(String? text) buildCountdownText;

  static Widget _kBuildCountdownText(String? text) {
    if (text == null) {
      return const SizedBox.shrink();
    }
    return Text(text);
  }

  @override
  State<ShutdownPanel> createState() => _ShutdownPanelState();
}

class _ShutdownPanelState extends State<ShutdownPanel> with ShutdownMixin {
  @override
  Widget build(BuildContext context) {
    final countdown = Obx(() => widget.buildCountdownText(countdownText.value));
    return widget.builder?.call(context, countdown, _startTimer, setState) ??
        countdown;
  }
}

mixin ShutdownMixin<T extends StatefulWidget> on State<T> {
  Timer? _countdownTimer;
  final RxnString countdownText = RxnString(null);
  late final List<StreamSubscription> _subscriptions;

  @override
  void initState() {
    super.initState();
    _startTimer();
    _subscriptions = [
      shutdownTimerService._deadline.listen((_) => _startTimer()),
      shutdownTimerService._isWaiting.listen((_) => _startTimer()),
    ];
  }

  void _updateCountdownTextEnd([String? value]) {
    _stopTimer();
    countdownText.value = value;
  }

  bool _updateCountdownText([_]) {
    if (shutdownTimerService.isWaiting) {
      _updateCountdownTextEnd('当前播放结束后关闭');
      return false;
    }
    final deadline = shutdownTimerService.deadline;
    if (deadline == null) {
      _updateCountdownTextEnd();
      return false;
    }
    final remaining = deadline.difference(DateTime.now());
    if (remaining <= .zero) {
      _updateCountdownTextEnd();
      return false;
    }
    countdownText.value = DurationUtils.formatDuration(remaining.inSeconds);
    return true;
  }

  void _startTimer() {
    _stopTimer();
    if (_updateCountdownText()) {
      _countdownTimer = .periodic(
        const Duration(seconds: 1),
        _updateCountdownText,
      );
    }
  }

  void _stopTimer() {
    if (_countdownTimer != null) {
      _countdownTimer!.cancel();
      _countdownTimer = null;
    }
  }

  @override
  void dispose() {
    for (final e in _subscriptions) {
      e.cancel();
    }
    _stopTimer();
    super.dispose();
  }
}
