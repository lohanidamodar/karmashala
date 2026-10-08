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
    this.onHiddenChanged,
    this.spacing = 0,
    this.keepsOne = true,
    super.key,
  });

  final List<Widget> children;

  /// Whether the first children are the least important (controls anchored
  /// at the end), rather than the last (facts read from the start).
  final bool yieldFromStart;

  /// Told, a frame after a layout changes it, which children are left out:
  /// for a host that offers them somewhere else.
  final ValueChanged<List<bool>>? onHiddenChanged;

  /// The gap between two children drawn side by side. A child with no width
  /// gets none, so one that says nothing leaves no hole.
  final double spacing;

  /// Whether the last child standing stays, given the row's width, rather
  /// than folding too: false for a row of controls a menu offers instead.
  final bool keepsOne;

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
        widget.onHiddenChanged?.call(hidden);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final children = widget.children;
    return _YieldingRowLayout(
      yieldFromStart: widget.yieldFromStart,
      spacing: widget.spacing,
      keepsOne: widget.keepsOne,
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
    required this.spacing,
    required this.keepsOne,
    required this.onLaidOut,
  });

  final bool yieldFromStart;
  final double spacing;
  final bool keepsOne;
  final ValueChanged<List<bool>> onLaidOut;

  @override
  RenderYieldingRow createRenderObject(BuildContext context) =>
      RenderYieldingRow(yieldFromStart, spacing, keepsOne)
        ..onLaidOut = onLaidOut;

  @override
  void updateRenderObject(
    BuildContext context,
    RenderYieldingRow renderObject,
  ) => renderObject
    ..yieldFromStart = yieldFromStart
    ..spacing = spacing
    ..keepsOne = keepsOne
    ..onLaidOut = onLaidOut;
}

class _YieldingParentData extends ContainerBoxParentData<RenderBox> {
  bool shown = true;
}

class RenderYieldingRow extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _YieldingParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _YieldingParentData> {
  RenderYieldingRow(
    this._yieldFromStart, [
    this._spacing = 0,
    this._keepsOne = true,
  ]);

  /// Told, after each layout, which children were left out.
  ValueChanged<List<bool>>? onLaidOut;

  bool _yieldFromStart;
  set yieldFromStart(bool value) {
    if (value == _yieldFromStart) return;
    _yieldFromStart = value;
    markNeedsLayout();
  }

  double _spacing;
  set spacing(double value) {
    if (value == _spacing) return;
    _spacing = value;
    markNeedsLayout();
  }

  bool _keepsOne;
  set keepsOne(bool value) {
    if (value == _keepsOne) return;
    _keepsOne = value;
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
    for (final child in children) {
      child.layout(natural, parentUsesSize: true);
      _data(child).shown = true;
    }
    // A child with no width is never what overflows, so it is never left out
    // and never counted as the one that stays.
    bool drawn(RenderBox child) => _data(child).shown && child.size.width > 0;
    double width() {
      final drawnChildren = children.where(drawn).toList();
      return drawnChildren.fold(0.0, (sum, c) => sum + c.size.width) +
          _spacing * math.max(0, drawnChildren.length - 1);
    }

    final order = [
      for (final child in _yieldFromStart ? children : children.reversed)
        if (child.size.width > 0) child,
    ];
    var total = width();
    var shown = order.length;
    for (final child in order) {
      if (total <= constraints.maxWidth || (_keepsOne && shown <= 1)) break;
      _data(child).shown = false;
      shown--;
      total = width();
    }
    if (total > constraints.maxWidth && shown > 0) {
      final last = order.firstWhere((c) => _data(c).shown);
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
    var first = true;
    for (final child in children) {
      final data = _data(child);
      // A child left out is placed past the end, where a reader of positions
      // finds it off the row rather than over the first child.
      if (!data.shown) {
        data.offset = Offset(size.width, 0);
        continue;
      }
      if (child.size.width > 0) {
        if (!first) x += _spacing;
        first = false;
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
