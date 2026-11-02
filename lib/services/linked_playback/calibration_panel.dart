import 'package:PiliPlus/services/linked_playback/band.dart';
import 'package:PiliPlus/services/linked_playback/calibration.dart';
import 'package:PiliPlus/services/linked_playback/calibration_signal.dart';
import 'package:PiliPlus/services/linked_playback/linked_playback.dart';
import 'package:PiliPlus/utils/permission_handler.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// 主控的校准面板：按频段对齐、校准时临时提高音量的设置，开始声学校准并显示
/// 进度与结果
Future<void> openLinkedCalibration() async {
  if (linkedPlayback.role.value != LinkedRole.leader) {
    SmartDialog.showToast('只有主控可以校准');
    return;
  }
  final context = Get.context;
  if (context == null) return;
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const _CalibrationDialog(),
  );
}

class _CalibrationDialog extends StatefulWidget {
  const _CalibrationDialog();

  @override
  State<_CalibrationDialog> createState() => _CalibrationDialogState();
}

class _CalibrationDialogState extends State<_CalibrationDialog> {
  /// 面板被关闭（含未经按钮的返回）时，仍在进行的校准随之取消
  @override
  void dispose() {
    linkedCalibration.cancel();
    super.dispose();
  }

  /// 关闭面板，校准结果随之关闭
  void _close() {
    linkedCalibration.close();
    Navigator.of(context).pop();
  }

  static String _step(CalibrationStage stage) => switch (stage) {
    CalibrationStage.pausing => '暂停播放',
    CalibrationStage.playing =>
      '播放测试音 第 ${linkedCalibration.round.value}/${CalibrationPlan.rounds} 轮',
    CalibrationStage.computing => '计算中',
    _ => '',
  };

  void _start() {
    if (!linkedPlayback.calibrate()) {
      SmartDialog.showToast(linkedPlayback.calibrationUnavailable ?? '暂时不能校准');
    }
  }

  static String _range(ChirpBand band) {
    final (from, to) = band.sweeps.first;
    return '${from.round()}~${to.round()}Hz';
  }

  static String _gap(int gap) =>
      '${gap < 0 ? '早' : '晚'} ${(gap.abs() / 1000).toStringAsFixed(1)} ms';

  /// 主控各频段的实测值
  static String _leaderGaps(BandGaps gaps) {
    if (gaps.isEmpty) return '未测到低频';
    return [
      for (final MapEntry(key: band, value: gap) in gaps.entries)
        '${_range(band)} ${_gap(gap)}',
    ].join('，');
  }

  /// 跟随端与主控比较所用的频段及差值
  static String _peerGap(String id) {
    final pair = linkedBand.pairFor(id);
    if (pair == null) return '没有与主控都测得的频段，按 0 计';
    return '按 ${_range(pair.band)} 比主控${_gap(pair.gap - pair.leaderGap)}';
  }

  /// 按频段对齐：在线跟随端的偏移随滑块实时平移
  List<Widget> _band(TextStyle? hint) {
    final available = linkedBand.available;
    final weight = linkedBand.weight.value;
    final position = switch (weight) {
      0.0 => '中高频',
      1.0 => '低频',
      _ => '低频 ${(weight * 100).round()}%',
    };
    return [
      Text('对齐频段：$position'),
      Text(
        available
            ? '低频重的内容听起来低音没对齐时往「低频」调，人声、高音没对齐时往「中高频」调；'
                  '各跟随端的延迟偏移随之平移，手动微调的部分保留'
            : '尚无低频的实测数据，校准后可用',
        style: hint,
      ),
      Row(
        children: [
          Text('中高频', style: hint),
          Expanded(
            child: Slider(
              divisions: 20,
              value: weight,
              label: '${(weight * 100).round()}%',
              onChanged: available ? linkedPlayback.setBandWeight : null,
            ),
          ),
          Text('低频', style: hint),
        ],
      ),
      if (available)
        Text(
          [
            '本机低频 ${_leaderGaps(linkedBand.leaderGaps.value)}',
            for (final peer in linkedPlayback.adjustablePeers)
              '${peer.name} 低频${_peerGap(peer.id)}',
          ].join('；'),
          style: hint,
        ),
    ];
  }

  /// 校准时临时提高各设备的音量
  List<Widget> _boost(TextStyle? hint) {
    final on = linkedCalibration.boost.value;
    final level = linkedCalibration.boostLevel.value;
    return [
      Row(
        children: [
          const Expanded(child: Text('校准时临时提高音量')),
          Switch(value: on, onChanged: linkedCalibration.setBoost),
        ],
      ),
      Text(
        on
            ? '音量低于 ${(level * 100).round()}% 的设备校准期间临时提高到此值，结束后恢复'
            : '按各设备当前的音量播放测试音',
        style: hint,
      ),
      if (on)
        Slider(
          min: 0.3,
          divisions: 7,
          value: level.clamp(0.3, 1.0).toDouble(),
          label: '${(level * 100).round()}%',
          onChanged: linkedCalibration.setBoostLevel,
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Obx(() {
      final stage = linkedCalibration.stage.value;
      final running = linkedCalibration.isRunning;
      final done = stage == CalibrationStage.done;
      final devices = linkedCalibration.devices;
      final hint = theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.outline,
      );
      final unavailable = linkedPlayback.calibrationUnavailable;
      return PopScope(
        canPop: !running,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) linkedCalibration.close();
        },
        child: AlertDialog(
          title: Text(switch (stage) {
            null => '声学校准',
            CalibrationStage.done => '校准完成',
            CalibrationStage.failed => '校准未完成',
            _ => '正在校准',
          }),
          content: SizedBox(
            width: 360,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 8,
                children: [
                  if (running) ...[
                    Text(_step(stage!)),
                    LinearProgressIndicator(
                      value: linkedCalibration.progress.value,
                    ),
                  ],
                  if (stage == null)
                    Text(
                      unavailable ??
                          '主控用麦克风录下各设备依次发出的提示音，自动设置各跟随端的'
                              '延迟偏移；约需十几秒，期间暂停播放，结束后恢复',
                      style: hint,
                    ),
                  if (linkedCalibration.message.value case final message?
                      when stage == CalibrationStage.failed)
                    Text(message),
                  if (running || done)
                    for (final device in devices)
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        spacing: 12,
                        children: [
                          Expanded(
                            child: Text(
                              device.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Flexible(
                            flex: done ? 2 : 1,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text(
                                  done ? device.result : device.status,
                                  textAlign: TextAlign.end,
                                  style: device.isReference ? hint : null,
                                ),
                                if (done)
                                  if (device.lowResult(devices.first)
                                      case final low?)
                                    Text(
                                      low,
                                      textAlign: TextAlign.end,
                                      style: hint,
                                    ),
                              ],
                            ),
                          ),
                        ],
                      ),
                  if (running)
                    Text('请保持安静，各设备会依次发出提示音', style: hint)
                  else ...[
                    const Divider(height: 8),
                    ..._band(hint),
                    const Divider(height: 8),
                    ..._boost(hint),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            if (running)
              TextButton(
                onPressed: linkedCalibration.cancel,
                child: const Text('取消'),
              )
            else if (done) ...[
              TextButton(
                onPressed: linkedCalibration.undo,
                child: const Text('撤销'),
              ),
              TextButton(onPressed: _start, child: const Text('重新校准')),
              TextButton(onPressed: _close, child: const Text('完成')),
            ] else ...[
              if (linkedCalibration.needsSettings.value)
                TextButton(
                  onPressed: openAppSettings,
                  child: const Text('打开设置'),
                ),
              TextButton(onPressed: _close, child: const Text('关闭')),
              TextButton(
                onPressed: unavailable == null ? _start : null,
                child: Text(stage == null ? '开始校准' : '重试'),
              ),
            ],
          ],
        ),
      );
    });
  }
}
