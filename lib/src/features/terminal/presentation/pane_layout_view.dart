import 'package:flutter/material.dart';

import '../domain/pane_layout.dart';

/// Width of the draggable divider between two panes.
const double kPaneDividerThickness = 8;

/// Called when a divider is dragged: move [delta] logical pixels from child
/// `index + 1` to child [index] of the split [splitId].
typedef PaneResizeCallback =
    void Function(String splitId, int index, double delta);

/// Renders a [PaneLayout] as nested [Row]s and [Column]s.
///
/// Takes a [paneBuilder] rather than building terminals itself so the layout can
/// be tested with cheap, instrumented children — which is how
/// `pane_layout_view_test.dart` proves that a pane inside a hidden `IndexedStack`
/// child records zero paints. That property is what keeps Loop 26's win: hidden
/// tabs must cost VT parsing but no painting.
class PaneLayoutView extends StatelessWidget {
  const PaneLayoutView({
    super.key,
    required this.layout,
    required this.paneBuilder,
    this.onResize,
  });

  final PaneLayout layout;
  final Widget Function(String paneId) paneBuilder;
  final PaneResizeCallback? onResize;

  @override
  Widget build(BuildContext context) => _build(layout.root);

  Widget _build(PaneNode node) {
    switch (node) {
      case PaneLeaf():
        return paneBuilder(node.id);
      case PaneSplit():
        final children = <Widget>[];
        for (var i = 0; i < node.children.length; i++) {
          if (i > 0) {
            children.add(
              PaneDivider(
                axis: node.axis,
                onDelta: onResize == null
                    ? null
                    : (delta) => onResize!(node.id, i - 1, delta),
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
  const PaneDivider({super.key, required this.axis, this.onDelta});

  final SplitAxis axis;
  final ValueChanged<double>? onDelta;

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
            ? (details) => onDelta!(details.delta.dx)
            : null,
        onVerticalDragUpdate: !horizontal && onDelta != null
            ? (details) => onDelta!(details.delta.dy)
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
