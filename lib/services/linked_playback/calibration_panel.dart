import 'package:PiliPlus/services/linked_playback/calibration.dart';
import 'package:PiliPlus/services/linked_playback/calibration_signal.dart';
import 'package:PiliPlus/services/linked_playback/linked_playback.dart';
import 'package:PiliPlus/utils/permission_handler.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// 开始声学校准并显示进度与结果；不能开始时提示原因
Future<void> openLinkedCalibration() async {
  if (!linkedPlayback.calibrate()) {
    SmartDialog.showToast(linkedPlayback.calibrationUnavailable ?? '暂时不能校准');
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
  bool _closing = false;

  /// 校准已取消、撤销或关闭结果时关闭对话框
  void _close() {
    if (_closing) return;
    _closing = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop();
    });
  }

  static String _step(CalibrationStage stage) => switch (stage) {
    CalibrationStage.pausing => '暂停播放',
    CalibrationStage.playing =>
      '播放测试音 第 ${linkedCalibration.round.value}/${CalibrationPlan.rounds} 轮',
    CalibrationStage.computing => '计算中',
    _ => '',
  };

  void _retry() {
    if (!linkedPlayback.calibrate()) {
      SmartDialog.showToast(linkedPlayback.calibrationUnavailable ?? '暂时不能校准');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Obx(() {
      final stage = linkedCalibration.stage.value;
      if (stage == null) {
        _close();
        return const SizedBox.shrink();
      }
      final running = linkedCalibration.isRunning;
      final done = stage == CalibrationStage.done;
      final devices = linkedCalibration.devices;
      final hint = theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.outline,
      );
      return PopScope(
        canPop: !running,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) {
            _closing = true;
            linkedCalibration.close();
          }
        },
        child: AlertDialog(
          title: Text(switch (stage) {
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
                    Text(_step(stage)),
                    LinearProgressIndicator(
                      value: linkedCalibration.progress.value,
                    ),
                  ],
                  if (linkedCalibration.message.value case final message?)
                    Text(message),
                  if (stage != CalibrationStage.failed)
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
                            child: Text(
                              done ? device.result : device.status,
                              textAlign: TextAlign.end,
                              style: device.isReference ? hint : null,
                            ),
                          ),
                        ],
                      ),
                  if (running)
                    Text('请保持安静，各设备会依次发出提示音', style: hint),
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
              TextButton(onPressed: _retry, child: const Text('重新校准')),
              TextButton(
                onPressed: linkedCalibration.close,
                child: const Text('完成'),
              ),
            ] else ...[
              if (linkedCalibration.needsSettings.value)
                TextButton(
                  onPressed: openAppSettings,
                  child: const Text('打开设置'),
                ),
              TextButton(
                onPressed: linkedCalibration.close,
                child: const Text('关闭'),
              ),
              TextButton(onPressed: _retry, child: const Text('重试')),
            ],
          ],
        ),
      );
    });
  }
}
