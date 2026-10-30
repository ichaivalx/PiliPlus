import 'package:PiliPlus/services/linked_playback/linked_playback.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// 拨轮式的逐格调节：沿拨轮拖动逐格滚动，逐格震动
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

  @override
  State<LinkedDial> createState() => _LinkedDialState();
}

class _LinkedDialState extends State<LinkedDial> {
  /// 每格的像素
  static const _extent = 10.0;

  /// 未满一格的拖动距离，正值为增大方向
  double _drag = 0;

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
    setState(() => _drag = 0);
  }

  @override
  Widget build(BuildContext context) {
    final vertical = widget.axis == Axis.vertical;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragUpdate: vertical ? _onUpdate : null,
      onVerticalDragEnd: vertical ? _onEnd : null,
      onVerticalDragCancel: vertical ? _onEnd : null,
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
  }
}

/// 延迟偏移的拨轮，每格 [LinkedPlayback.offsetStepUs]
class LinkedOffsetDial extends StatelessWidget {
  const LinkedOffsetDial({
    super.key,
    required this.axis,
    required this.length,
    this.thickness = 36,
    this.color = Colors.white,
    this.indicatorColor,
    this.onInteraction,
  });

  final Axis axis;
  final double length;
  final double thickness;
  final Color color;
  final Color? indicatorColor;
  final VoidCallback? onInteraction;

  @override
  Widget build(BuildContext context) {
    return Obx(
      () => LinkedDial(
        index: linkedPlayback.offsetUs.value ~/ LinkedPlayback.offsetStepUs,
        onSteps: (steps) => linkedPlayback.setOffset(
          linkedPlayback.offsetUs.value + steps * LinkedPlayback.offsetStepUs,
        ),
        axis: axis,
        length: length,
        thickness: thickness,
        color: color,
        indicatorColor: indicatorColor,
        onInteraction: onInteraction,
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

/// 偏移值的文本，精确到 0.1ms
String formatLinkedOffset(int us) {
  final text = (us / 1000).toStringAsFixed(1);
  return '${us > 0 ? '+' : ''}$text ms';
}
