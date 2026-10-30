import 'package:PiliPlus/services/linked_playback/linked_playback.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// 拨轮式的延迟偏移调节：沿拨轮拖动逐格滚动，每格
/// [LinkedPlayback.offsetStepUs]，逐格震动
class LinkedOffsetDial extends StatefulWidget {
  const LinkedOffsetDial({
    super.key,
    required this.axis,
    required this.length,
    this.thickness = 36,
    this.color = Colors.white,
    this.indicatorColor,
    this.onInteraction,
  });

  /// 拖动方向：竖直时向上增大，水平时向右增大
  final Axis axis;
  final double length;
  final double thickness;
  final Color color;
  final Color? indicatorColor;

  /// 拖动期间持续调用，供播放器保持控件显示
  final VoidCallback? onInteraction;

  @override
  State<LinkedOffsetDial> createState() => _LinkedOffsetDialState();
}

class _LinkedOffsetDialState extends State<LinkedOffsetDial> {
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
      linkedPlayback.setOffset(
        linkedPlayback.offsetUs.value + steps * LinkedPlayback.offsetStepUs,
      );
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
        child: Obx(
          () => CustomPaint(
            painter: _DialPainter(
              value: linkedPlayback.offsetUs.value,
              drag: _drag,
              axis: widget.axis,
              extent: _extent,
              color: widget.color,
              indicatorColor:
                  widget.indicatorColor ?? ColorScheme.of(context).primary,
            ),
          ),
        ),
      ),
    );
  }
}

class _DialPainter extends CustomPainter {
  _DialPainter({
    required this.value,
    required this.drag,
    required this.axis,
    required this.extent,
    required this.color,
    required this.indicatorColor,
  });

  final int value;
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
    final current = value ~/ LinkedPlayback.offsetStepUs;
    final visible = (mid / extent).ceil() + 1;
    final paint = Paint()..strokeCap = StrokeCap.round;
    for (var i = -visible; i <= visible; i++) {
      final index = current + i;
      // 刻度随手指移动，较大值竖直时在下方、水平时在左侧，向中心滚入
      final along = vertical
          ? mid + i * extent - drag
          : mid - i * extent + drag;
      final distance = (along - mid).abs() / mid;
      if (distance > 1) continue;
      final major = index % 10 == 0;
      final medium = index.isEven;
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
      value != oldDelegate.value ||
      drag != oldDelegate.drag ||
      color != oldDelegate.color ||
      indicatorColor != oldDelegate.indicatorColor;
}

/// 偏移值的文本，精确到 0.1ms
String formatLinkedOffset(int us) {
  final text = (us / 1000).toStringAsFixed(1);
  return '${us > 0 ? '+' : ''}$text ms';
}

/// 覆盖在播放器左侧的紧凑拨轮：联动开启且同步播放时随播放器控件显示
class LinkedOffsetOverlay extends StatelessWidget {
  const LinkedOffsetOverlay({
    super.key,
    required this.length,
    required this.onInteraction,
  });

  /// 拨轮长度
  final double length;
  final VoidCallback onInteraction;

  @override
  Widget build(BuildContext context) {
    const textStyle = TextStyle(color: Colors.white, fontSize: 11);
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: Color(0x45000000),
        borderRadius: BorderRadius.all(Radius.circular(8)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Obx(
              () => Text(
                formatLinkedOffset(linkedPlayback.offsetUs.value),
                style: textStyle,
              ),
            ),
            LinkedOffsetDial(
              axis: Axis.vertical,
              length: length,
              thickness: 44,
              onInteraction: onInteraction,
            ),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                onInteraction();
                linkedPlayback.setOffset(0);
              },
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Text('归零', style: textStyle),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
