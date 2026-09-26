import 'package:xterm2/core.dart';

/// The visible screen of [terminal] as plain text: one line per row, trailing
/// blanks trimmed, and the empty rows below the last drawn one dropped. What a
/// phone is shown of a session while no desktop app can read the agent's own
/// record — no colours, no cursor, nothing to re-render.
String screenTextOf(Terminal terminal) {
  final buffer = terminal.buffer;
  final lines = <String>[];
  final from = buffer.scrollBack < 0 ? 0 : buffer.scrollBack;
  for (var row = from; row < buffer.height; row++) {
    lines.add(buffer.lines[row].getText().trimRight());
  }
  while (lines.isNotEmpty && lines.last.isEmpty) {
    lines.removeLast();
  }
  return lines.join('\n');
}
