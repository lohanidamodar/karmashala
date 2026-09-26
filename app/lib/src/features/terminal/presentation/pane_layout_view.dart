import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'package:karmashala_terminal_core/geometry.dart';

/// Width of the draggable divider between two panes.
const double kPaneDividerThickness = 8;

/// Called when a divider is dragged: move [share] of split [splitId]'s own
/// extent from child `index + 1` to [index]. A **share, not pixels**.
typedef PaneResizeCallback =
    void Function(String splitId, int index, double share);

/// Renders a [PaneLayout] as nested [Row]s and [Column]s. [regionBuilder] is
/// what lets a test prove a hidden tab's region records zero paints.
class PaneLayoutView extends StatelessWidget {
  const PaneLayoutView({
    super.key,
    required this.layout,
    required this.regionBuilder,
    this.onResize,
  });

  final PaneLayout layout;
  final Widget Function(PaneGroup group) regionBuilder;
  final PaneResizeCallback? onResize;

  @override
  Widget build(BuildContext context) => _build(layout.root);

  Widget _build(PaneNode node) {
    switch (node) {
      case PaneGroup():
        return regionBuilder(node);
      case PaneSplit():
        final children = <Widget>[];
        for (var i = 0; i < node.children.length; i++) {
          if (i > 0) {
            children.add(
              PaneDivider(
                axis: node.axis,
                paneCount: node.children.length,
                onDelta: onResize == null
                    ? null
                    : (share) => onResize!(node.id, i - 1, share),
              ),
            );
          }
          // Flex is an int, so weights are scaled rather than used directly.
          children.add(
            Expanded(
              flex: (node.weights[i] * 10000).round().clamp(1, 1 << 30),
              child: _build(node.children[i]),
            ),
          );
        }
        return node.axis == SplitAxis.horizontal
            ? Row(children: children)
            : Column(children: children);
    }
  }
}

/// The draggable line between two panes of a split.
class PaneDivider extends StatelessWidget {
  const PaneDivider({
    super.key,
    required this.axis,
    required this.paneCount,
    this.onDelta,
  });

  final SplitAxis axis;

  /// How many children the split has, so the room its dividers take comes off
  /// the extent its weights share out.
  final int paneCount;

  /// Handed the drag as a share of that room, ready for [PaneLayout.resize].
  final ValueChanged<double>? onDelta;

  /// The extent this divider's split gives its weights, or null before layout.
  /// Measured at drag time: handing it down means a `LayoutBuilder` per split.
  double? _room(BuildContext context) {
    final flex = context.findAncestorRenderObjectOfType<RenderFlex>();
    if (flex == null || !flex.hasSize) return null;
    final extent = axis == SplitAxis.horizontal
        ? flex.size.width
        : flex.size.height;
    final room = extent - (paneCount - 1) * kPaneDividerThickness;
    return room > 0 ? room : null;
  }

  void _report(BuildContext context, double pixels) {
    final room = _room(context);
    if (room != null) onDelta!(pixels / room);
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.outlineVariant;
    final horizontal = axis == SplitAxis.horizontal;
    return MouseRegion(
      cursor: horizontal
          ? SystemMouseCursors.resizeLeftRight
          : SystemMouseCursors.resizeUpDown,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragUpdate: horizontal && onDelta != null
            ? (details) => _report(context, details.delta.dx)
            : null,
        onVerticalDragUpdate: !horizontal && onDelta != null
            ? (details) => _report(context, details.delta.dy)
            : null,
        child: horizontal
            ? SizedBox(
                width: kPaneDividerThickness,
                child: Center(child: Container(width: 1, color: color)),
              )
            : SizedBox(
                height: kPaneDividerThickness,
                child: Center(child: Container(height: 1, color: color)),
              ),
      ),
    );
  }
}
