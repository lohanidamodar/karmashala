import 'package:flutter/material.dart';

/// A thin draggable divider that reports horizontal drag deltas — used to resize
/// the desktop panes (Explorer, detail sidebar). Shows a resize cursor on hover.
class ResizeHandle extends StatelessWidget {
  const ResizeHandle({required this.onDelta, this.onEnd, super.key});

  final ValueChanged<double> onDelta;
  final VoidCallback? onEnd;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragUpdate: (d) => onDelta(d.delta.dx),
        onHorizontalDragEnd: (_) => onEnd?.call(),
        child: SizedBox(
          width: 8,
          child: Center(
            child: Container(width: 1, color: scheme.outlineVariant),
          ),
        ),
      ),
    );
  }
}
