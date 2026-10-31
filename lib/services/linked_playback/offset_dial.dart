import 'dart:async';

import 'package:PiliPlus/services/linked_playback/linked_playback.dart';
import 'package:flutter/gestures.dart'
    show GestureBinding, PointerScrollEvent, PointerSignalEvent;
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// 拨轮式的逐格调节：沿拨轮拖动逐格滚动，逐格震动；鼠标滚轮每次滚动一格
class LinkedDial extends StatefulWidget {
  const LinkedDial({
    super.key,
    required this.index,
    required this.onSteps,
    required this.axis,
    required this.length,
    this.thickness = 36,
    this.color = Colors.white,
    this.indicatorColor,
    this.onInteraction,
    this.onDragging,
  });

  /// 当前值所在的格
  final int index;

  /// 拖过的格数，正值为增大方向
  final ValueChanged<int> onSteps;

  /// 拖动方向：竖直时向上增大，水平时向右增大
  final Axis axis;
  final double length;
  final double thickness;
  final Color color;
  final Color? indicatorColor;

  /// 拖动期间持续调用，供播放器保持控件显示
  final VoidCallback? onInteraction;

  /// 拖动或连续滚动滚轮开始时以 true、结束或取消（含期间被移除）时以 false 调用
  final ValueChanged<bool>? onDragging;

  @override
  State<LinkedDial> createState() => _LinkedDialState();
}

class _LinkedDialState extends State<LinkedDial> {
  /// 每格的像素
  static const _extent = 10.0;

  /// 滚轮停止滚动此时长后视为一次调节结束
  static const _wheelIdle = Duration(milliseconds: 500);

  Timer? _wheelTimer;

  /// 未满一格的拖动距离，正值为增大方向
  double _drag = 0;

  bool _dragging = false;

  void _setDragging(bool dragging) {
    if (_dragging == dragging) return;
    _dragging = dragging;
    widget.onDragging?.call(dragging);
  }

  void _onStart(DragStartDetails details) {
    _wheelTimer?.cancel();
    _wheelTimer = null;
    _setDragging(true);
  }

  void _onUpdate(DragUpdateDetails details) {
    widget.onInteraction?.call();
    _drag += widget.axis == Axis.vertical
        ? -details.delta.dy
        : details.delta.dx;
    final steps = (_drag / _extent).truncate();
    if (steps != 0) {
      _drag -= steps * _extent;
      HapticFeedback.selectionClick();
      widget.onSteps(steps);
    }
    setState(() {});
  }

  void _onEnd([_]) {
    _setDragging(false);
    setState(() => _drag = 0);
  }

  @override
  void dispose() {
    _wheelTimer?.cancel();
    _setDragging(false);
    super.dispose();
  }

  /// 滚轮向上或向右增大；优先于播放器的滚轮调音量
  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (event) {
      final delta = (event as PointerScrollEvent).scrollDelta;
      final amount = delta.dy != 0 ? -delta.dy : delta.dx;
      if (amount == 0) return;
      // 连续滚动视为一次调节，停止滚动后结束
      _setDragging(true);
      _wheelTimer?.cancel();
      _wheelTimer = Timer(_wheelIdle, () {
        _wheelTimer = null;
        _setDragging(false);
      });
      widget.onInteraction?.call();
      widget.onSteps(amount > 0 ? 1 : -1);
    });
  }

  @override
  Widget build(BuildContext context) {
    final vertical = widget.axis == Axis.vertical;
    final dial = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragStart: vertical ? _onStart : null,
      onVerticalDragUpdate: vertical ? _onUpdate : null,
      onVerticalDragEnd: vertical ? _onEnd : null,
      onVerticalDragCancel: vertical ? _onEnd : null,
      onHorizontalDragStart: vertical ? null : _onStart,
      onHorizontalDragUpdate: vertical ? null : _onUpdate,
      onHorizontalDragEnd: vertical ? null : _onEnd,
      onHorizontalDragCancel: vertical ? null : _onEnd,
      child: SizedBox(
        width: vertical ? widget.thickness : widget.length,
        height: vertical ? widget.length : widget.thickness,
        child: CustomPaint(
          painter: _DialPainter(
            index: widget.index,
            drag: _drag,
            axis: widget.axis,
            extent: _extent,
            color: widget.color,
            indicatorColor:
                widget.indicatorColor ?? ColorScheme.of(context).primary,
          ),
        ),
      ),
    );
    return Listener(onPointerSignal: _onPointerSignal, child: dial);
  }
}

/// 当前调节的延迟偏移（跟随端为本机，主控为当前跟随端）的拨轮，每格
/// [LinkedPlayback.offsetStepUs]：向 [linkedSlowerLabel] 一端（左或下）该设备
/// 出声更晚，向 [linkedFasterLabel] 一端更早；调节的跟随端变化时拨轮随之重建，
/// 当前拖动结束
class LinkedOffsetDial extends StatelessWidget {
  const LinkedOffsetDial({
    super.key,
    required this.axis,
    required this.length,
    this.thickness = 36,
    this.color = Colors.white,
    this.indicatorColor,
    this.onInteraction,
    this.onDragging,
  });

  final Axis axis;
  final double length;
  final double thickness;
  final Color color;
  final Color? indicatorColor;
  final VoidCallback? onInteraction;
  final ValueChanged<bool>? onDragging;

  @override
  Widget build(BuildContext context) {
    return Obx(
      () => LinkedDial(
        key: ValueKey<String?>(linkedPlayback.selectedPeer?.id),
        // 偏移为正时出声更晚，拨轮的增大方向为更早
        index:
            -(linkedPlayback.currentOffsetUs ?? 0) ~/
            LinkedPlayback.offsetStepUs,
        onSteps: (steps) =>
            linkedPlayback.adjustOffset(-steps * LinkedPlayback.offsetStepUs),
        axis: axis,
        length: length,
        thickness: thickness,
        color: color,
        indicatorColor: indicatorColor,
        onInteraction: onInteraction,
        onDragging: onDragging,
      ),
    );
  }
}

class _DialPainter extends CustomPainter {
  _DialPainter({
    required this.index,
    required this.drag,
    required this.axis,
    required this.extent,
    required this.color,
    required this.indicatorColor,
  });

  final int index;
  final double drag;
  final Axis axis;
  final double extent;
  final Color color;
  final Color indicatorColor;

  @override
  void paint(Canvas canvas, Size size) {
    final vertical = axis == Axis.vertical;
    final length = vertical ? size.height : size.width;
    final thickness = vertical ? size.width : size.height;
    final mid = length / 2;
    final visible = (mid / extent).ceil() + 1;
    final paint = Paint()..strokeCap = StrokeCap.round;
    for (var i = -visible; i <= visible; i++) {
      final tickIndex = index + i;
      // 刻度随手指移动，较大值竖直时在下方、水平时在左侧，向中心滚入
      final along = vertical
          ? mid + i * extent - drag
          : mid - i * extent + drag;
      final distance = (along - mid).abs() / mid;
      if (distance > 1) continue;
      final major = tickIndex % 10 == 0;
      final medium = tickIndex.isEven;
      final tick = thickness * (major ? 0.6 : (medium ? 0.4 : 0.25));
      paint
        ..strokeWidth = major ? 2 : 1.2
        ..color = color.withValues(alpha: (1 - distance) * 0.9);
      final start = (thickness - tick) / 2;
      if (vertical) {
        canvas.drawLine(
          Offset(start, along),
          Offset(start + tick, along),
          paint,
        );
      } else {
        canvas.drawLine(
          Offset(along, start),
          Offset(along, start + tick),
          paint,
        );
      }
    }
    final indicator = Paint()
      ..color = indicatorColor
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    if (vertical) {
      canvas.drawLine(Offset(2, mid), Offset(size.width - 2, mid), indicator);
    } else {
      canvas.drawLine(Offset(mid, 2), Offset(mid, size.height - 2), indicator);
    }
  }

  @override
  bool shouldRepaint(_DialPainter oldDelegate) =>
      index != oldDelegate.index ||
      drag != oldDelegate.drag ||
      color != oldDelegate.color ||
      indicatorColor != oldDelegate.indicatorColor;
}

/// 偏移拨轮两端的文本
const linkedSlowerLabel = '慢一点';
const linkedFasterLabel = '快一点';

/// 偏移值的文本，按 0.5ms 取整：偏移为正（出声更晚）为「慢」，为负为「快」，
/// 整毫秒不带小数，半毫秒带 .5，零为「0 ms」
String formatLinkedOffset(int us) {
  final halves = (us.abs() / 500).round();
  if (halves == 0) return '0 ms';
  final text = '${halves ~/ 2}${halves.isOdd ? '.5' : ''}';
  return '${us > 0 ? '慢' : '快'} $text ms';
}
