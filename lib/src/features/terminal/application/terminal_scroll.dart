import 'package:flutter/widgets.dart';

/// The scroll offset that centres buffer line [line], or null when there is
/// nothing to scroll. `RenderTerminal` sets content height to
/// `lines.length * cellHeight`, so the line height can be recovered from the
/// scroll metrics without reaching into the vendored render object.
double? terminalLineOffset({
  required int line,
  required int lineCount,
  required double maxScrollExtent,
  required double viewportDimension,
}) {
  if (maxScrollExtent <= 0 || lineCount <= 0) return null;
  final lineHeight = (maxScrollExtent + viewportDimension) / lineCount;
  final offset = line * lineHeight - viewportDimension / 2 + lineHeight / 2;
  return offset.clamp(0.0, maxScrollExtent);
}

/// Centres buffer line [line] of a pane with [lineCount] lines.
///
/// Does nothing when the pane is not laid out yet or has nothing to scroll.
void scrollTerminalToLine(
  ScrollController controller, {
  required int line,
  required int lineCount,
}) {
  if (!controller.hasClients) return;
  final position = controller.position;
  final offset = terminalLineOffset(
    line: line,
    lineCount: lineCount,
    maxScrollExtent: position.maxScrollExtent,
    viewportDimension: position.viewportDimension,
  );
  if (offset == null) return;
  position.jumpTo(
    offset.clamp(position.minScrollExtent, position.maxScrollExtent),
  );
}
