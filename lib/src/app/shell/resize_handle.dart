import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A thin draggable divider that reports drag deltas, for the desktop panes.
///
/// [axis] is the direction the handle *moves* in: [Axis.horizontal] is a
/// vertical bar dragged left/right; [Axis.vertical] is dragged up/down.
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
        ),
      ),
    );
  }
}

class _ResizeIntent extends Intent {
  const _ResizeIntent(this.delta);

  final double delta;
}
