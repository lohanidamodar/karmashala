import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A thin draggable divider that reports drag deltas. [axis] is the direction
/// the handle *moves* in: [Axis.horizontal] is a vertical bar dragged sideways.
class ResizeHandle extends StatelessWidget {
  const ResizeHandle({
    required this.onDelta,
    this.onEnd,
    this.axis = Axis.horizontal,
    this.semanticLabel,
    super.key,
  });

  final ValueChanged<double> onDelta;
  final VoidCallback? onEnd;
  final Axis axis;
  final String? semanticLabel;

  /// How much width the handle itself takes across its axis.
  static const thickness = 8.0;

  static const _keyboardStep = 16.0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final horizontal = axis == Axis.horizontal;
    void move(double delta) {
      onDelta(delta);
      onEnd?.call();
    }

    return Semantics(
      label:
          semanticLabel ??
          (horizontal ? 'Resize pane width' : 'Resize pane height'),
      focusable: true,
      onIncrease: () => move(_keyboardStep),
      onDecrease: () => move(-_keyboardStep),
      child: FocusableActionDetector(
        shortcuts: {
          if (horizontal) ...{
            const SingleActivator(LogicalKeyboardKey.arrowLeft):
                const _ResizeIntent(-_keyboardStep),
            const SingleActivator(LogicalKeyboardKey.arrowRight):
                const _ResizeIntent(_keyboardStep),
          } else ...{
            const SingleActivator(LogicalKeyboardKey.arrowUp):
                const _ResizeIntent(-_keyboardStep),
            const SingleActivator(LogicalKeyboardKey.arrowDown):
                const _ResizeIntent(_keyboardStep),
          },
        },
        actions: {
          _ResizeIntent: CallbackAction<_ResizeIntent>(
            onInvoke: (intent) {
              move(intent.delta);
              return null;
            },
          ),
        },
        child: MouseRegion(
          cursor: horizontal
              ? SystemMouseCursors.resizeLeftRight
              : SystemMouseCursors.resizeUpDown,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onHorizontalDragUpdate: horizontal
                ? (d) => onDelta(d.delta.dx)
                : null,
            onHorizontalDragEnd: horizontal ? (_) => onEnd?.call() : null,
            onVerticalDragUpdate: horizontal
                ? null
                : (d) => onDelta(d.delta.dy),
            onVerticalDragEnd: horizontal ? null : (_) => onEnd?.call(),
            child: horizontal
                ? SizedBox(
                    width: thickness,
                    child: Center(
                      child: Container(width: 1, color: scheme.outlineVariant),
                    ),
                  )
                : SizedBox(
                    height: thickness,
                    child: Center(
                      child: Container(height: 1, color: scheme.outlineVariant),
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

/// A column of a fixed [width] with a [ResizeHandle] on one edge. Holds no
/// state: the owner decides the width, so nothing is written during a build.
class ResizableColumn extends StatelessWidget {
  const ResizableColumn({
    required this.width,
    required this.onResize,
    required this.child,
    this.onResizeEnd,
    this.handleAtStart = false,
    this.semanticLabel,
    super.key,
  });

  final double width;

  /// The width a drag asks for, before the owner clamps it.
  final ValueChanged<double> onResize;
  final VoidCallback? onResizeEnd;

  /// Whether the handle is on the leading edge, so dragging it left widens.
  final bool handleAtStart;
  final String? semanticLabel;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final handle = ResizeHandle(
      semanticLabel: semanticLabel,
      onDelta: (dx) => onResize(width + (handleAtStart ? -dx : dx)),
      onEnd: onResizeEnd,
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (handleAtStart) handle,
        SizedBox(width: width, child: child),
        if (!handleAtStart) handle,
      ],
    );
  }
}

class _ResizeIntent extends Intent {
  const _ResizeIntent(this.delta);

  final double delta;
}
