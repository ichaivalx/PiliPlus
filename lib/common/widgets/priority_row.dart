import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals, setEquals;
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// 横向排列的子项，前 [optional] 个可隐藏：其余子项总是显示，可隐藏的按
/// [priorities] 的先后在总宽度不超过 [maxWidth] 时显示，放不下的不显示、不占
/// 位置，并通过 [onHidden] 告知其序号（宽度为 0 的不算）
class PriorityRow extends MultiChildRenderObjectWidget {
  const PriorityRow({
    super.key,
    required this.maxWidth,
    required this.optional,
    required this.priorities,
    this.onHidden,
    super.children,
  });

  final double maxWidth;
  final int optional;

  /// 可隐藏子项的序号，先保留排在前面的
  final List<int> priorities;

  /// 隐藏的子项变化时在布局中调用，不应在其中改变界面
  final ValueChanged<Set<int>>? onHidden;

  @override
  RenderPriorityRow createRenderObject(BuildContext context) =>
      RenderPriorityRow(
        maxWidth: maxWidth,
        optional: optional,
        priorities: priorities,
        onHidden: onHidden,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    RenderPriorityRow renderObject,
  ) {
    renderObject
      ..maxWidth = maxWidth
      ..optional = optional
      ..priorities = priorities
      ..onHidden = onHidden;
  }
}

class _PriorityRowParentData extends ContainerBoxParentData<RenderBox> {
  bool visible = true;
}

class RenderPriorityRow extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _PriorityRowParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _PriorityRowParentData> {
  RenderPriorityRow({
    required double maxWidth,
    required int optional,
    required List<int> priorities,
    this.onHidden,
  }) : _maxWidth = maxWidth,
       _optional = optional,
       _priorities = priorities;

  double _maxWidth;
  set maxWidth(double value) {
    if (_maxWidth == value) return;
    _maxWidth = value;
    markNeedsLayout();
  }

  int _optional;
  set optional(int value) {
    if (_optional == value) return;
    _optional = value;
    markNeedsLayout();
  }

  List<int> _priorities;
  set priorities(List<int> value) {
    if (listEquals(_priorities, value)) return;
    _priorities = value;
    markNeedsLayout();
  }

  ValueChanged<Set<int>>? onHidden;
  Set<int> _hidden = const {};

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _PriorityRowParentData) {
      child.parentData = _PriorityRowParentData();
    }
  }

  @override
  void performLayout() {
    final children = getChildrenAsList();
    final childConstraints = BoxConstraints(maxHeight: constraints.maxHeight);
    var used = 0.0;
    for (var i = 0; i < children.length; i++) {
      children[i].layout(childConstraints, parentUsesSize: true);
      if (i >= _optional) used += children[i].size.width;
    }
    final visible = List.generate(children.length, (i) => i >= _optional);
    for (final i in _priorities) {
      if (i >= _optional || i >= children.length) continue;
      final width = children[i].size.width;
      if (used + width <= _maxWidth) {
        visible[i] = true;
        used += width;
      }
    }
    var height = 0.0;
    for (var i = 0; i < children.length; i++) {
      if (visible[i]) height = math.max(height, children[i].size.height);
    }
    var x = 0.0;
    for (var i = 0; i < children.length; i++) {
      final child = children[i];
      final parentData = child.parentData! as _PriorityRowParentData
        ..visible = visible[i];
      if (!visible[i]) continue;
      parentData.offset = Offset(x, (height - child.size.height) / 2);
      x += child.size.width;
    }
    size = constraints.constrain(Size(x, height));
    final hidden = {
      for (var i = 0; i < children.length; i++)
        if (!visible[i] && children[i].size.width > 0) i,
    };
    if (!setEquals(hidden, _hidden)) {
      _hidden = hidden;
      onHidden?.call(hidden);
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    var child = firstChild;
    while (child != null) {
      final parentData = child.parentData! as _PriorityRowParentData;
      if (parentData.visible) {
        context.paintChild(child, parentData.offset + offset);
      }
      child = parentData.nextSibling;
    }
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    var child = lastChild;
    while (child != null) {
      final parentData = child.parentData! as _PriorityRowParentData;
      if (parentData.visible &&
          result.addWithPaintOffset(
            offset: parentData.offset,
            position: position,
            hitTest: (result, transformed) =>
                child!.hitTest(result, position: transformed),
          )) {
        return true;
      }
      child = parentData.previousSibling;
    }
    return false;
  }

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    var child = firstChild;
    while (child != null) {
      final parentData = child.parentData! as _PriorityRowParentData;
      if (parentData.visible) visitor(child);
      child = parentData.nextSibling;
    }
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    final parentData = child.parentData! as _PriorityRowParentData;
    if (!parentData.visible) {
      transform.setZero();
      return;
    }
    super.applyPaintTransform(child, transform);
  }
}
