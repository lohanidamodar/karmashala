import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// A row that keeps its children whole: those that do not fit its width are
/// left out, the least important first, rather than cut at an edge or
/// scrolled away. Children lay out at their natural width; one left alone is
/// given the row's width instead, so a label in it can end with an ellipsis.
/// A child left out takes no focus and is not read by a screen reader.
class YieldingRow extends StatefulWidget {
  const YieldingRow({
    required this.children,
    this.yieldFromStart = true,
    super.key,
  });

  final List<Widget> children;

  /// Whether the first children are the least important (controls anchored
  /// at the end), rather than the last (facts read from the start).
  final bool yieldFromStart;

  @override
  State<YieldingRow> createState() => _YieldingRowState();
}

class _YieldingRowState extends State<YieldingRow> {
  /// Which children the last layout left out. Known only after layout, so
  /// focus follows a frame later.
  List<bool> _hidden = const [];

  void _laidOut(List<bool> hidden) {
    if (listEquals(hidden, _hidden)) return;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (mounted && !listEquals(hidden, _hidden)) {
        setState(() => _hidden = hidden);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final children = widget.children;
    return _YieldingRowLayout(
      yieldFromStart: widget.yieldFromStart,
      onLaidOut: _laidOut,
      children: [
        for (var i = 0; i < children.length; i++)
          ExcludeFocus(
            key: children[i].key == null ? null : ObjectKey(children[i].key),
            excluding: i < _hidden.length && _hidden[i],
            child: children[i],
          ),
      ],
    );
  }
}

class _YieldingRowLayout extends MultiChildRenderObjectWidget {
  const _YieldingRowLayout({
    required super.children,
    required this.yieldFromStart,
    required this.onLaidOut,
  });

  final bool yieldFromStart;
  final ValueChanged<List<bool>> onLaidOut;

  @override
  RenderYieldingRow createRenderObject(BuildContext context) =>
      RenderYieldingRow(yieldFromStart)..onLaidOut = onLaidOut;

  @override
  void updateRenderObject(
    BuildContext context,
    RenderYieldingRow renderObject,
  ) => renderObject
    ..yieldFromStart = yieldFromStart
    ..onLaidOut = onLaidOut;
}

class _YieldingParentData extends ContainerBoxParentData<RenderBox> {
  bool shown = true;
}

class RenderYieldingRow extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _YieldingParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _YieldingParentData> {
  RenderYieldingRow(this._yieldFromStart);

  /// Told, after each layout, which children were left out.
  ValueChanged<List<bool>>? onLaidOut;

  bool _yieldFromStart;
  set yieldFromStart(bool value) {
    if (value == _yieldFromStart) return;
    _yieldFromStart = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _YieldingParentData) {
      child.parentData = _YieldingParentData();
    }
  }

  List<RenderBox> get _children => [
    for (var child = firstChild; child != null; child = childAfter(child))
      child,
  ];

  _YieldingParentData _data(RenderBox child) =>
      child.parentData! as _YieldingParentData;

  @override
  void performLayout() {
    final children = _children;
    final natural = BoxConstraints(maxHeight: constraints.maxHeight);
    var total = 0.0;
    for (final child in children) {
      child.layout(natural, parentUsesSize: true);
      _data(child).shown = true;
      total += child.size.width;
    }
    final order = _yieldFromStart ? children : children.reversed.toList();
    var shown = children.length;
    for (final child in order) {
      if (total <= constraints.maxWidth || shown == 1) break;
      _data(child).shown = false;
      total -= child.size.width;
      shown--;
    }
    if (total > constraints.maxWidth) {
      final last = children.firstWhere((c) => _data(c).shown);
      last.layout(
        natural.copyWith(maxWidth: constraints.maxWidth),
        parentUsesSize: true,
      );
      total = last.size.width;
    }

    var height = 0.0;
    for (final child in children) {
      if (_data(child).shown) height = math.max(height, child.size.height);
    }
    size = constraints.constrain(Size(total, height));
    var x = 0.0;
    for (final child in children) {
      final data = _data(child);
      // A child left out is placed past the end, where a reader of positions
      // finds it off the row rather than over the first child.
      if (!data.shown) {
        data.offset = Offset(size.width, 0);
        continue;
      }
      data.offset = Offset(x, (size.height - child.size.height) / 2);
      x += child.size.width;
    }
    onLaidOut?.call([for (final child in children) !_data(child).shown]);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    for (final child in _children) {
      final data = _data(child);
      if (data.shown) context.paintChild(child, data.offset + offset);
    }
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    for (final child in _children.reversed) {
      final data = _data(child);
      if (!data.shown) continue;
      final hit = result.addWithPaintOffset(
        offset: data.offset,
        position: position,
        hitTest: (result, transformed) =>
            child.hitTest(result, position: transformed),
      );
      if (hit) return true;
    }
    return false;
  }

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    for (final child in _children) {
      if (_data(child).shown) visitor(child);
    }
  }
}
