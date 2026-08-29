import 'package:flutter/material.dart';

/// A thin draggable divider that reports drag deltas — used to resize the
/// desktop panes (Explorer, detail sidebar) and the terminal dock.
///
/// [axis] is the direction the handle *moves* in: [Axis.horizontal] is a
/// vertical bar dragged left/right (the default, and what the pane dividers
/// use); [Axis.vertical] is a horizontal bar dragged up/down.
class ResizeHandle extends StatelessWidget {
  const ResizeHandle({
    required this.onDelta,
    this.onEnd,
    this.axis = Axis.horizontal,
    super.key,
  });

  final ValueChanged<double> onDelta;
  final VoidCallback? onEnd;
  final Axis axis;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final horizontal = axis == Axis.horizontal;
    return MouseRegion(
      cursor: horizontal
          ? SystemMouseCursors.resizeLeftRight
          : SystemMouseCursors.resizeUpDown,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragUpdate: horizontal ? (d) => onDelta(d.delta.dx) : null,
        onHorizontalDragEnd: horizontal ? (_) => onEnd?.call() : null,
        onVerticalDragUpdate: horizontal ? null : (d) => onDelta(d.delta.dy),
        onVerticalDragEnd: horizontal ? null : (_) => onEnd?.call(),
        child: horizontal
            ? SizedBox(
                width: 8,
                child: Center(
                  child: Container(width: 1, color: scheme.outlineVariant),
                ),
              )
            : SizedBox(
                height: 8,
                child: Center(
                  child: Container(height: 1, color: scheme.outlineVariant),
                ),
              ),
      ),
    );
  }
}
