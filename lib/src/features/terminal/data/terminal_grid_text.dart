import 'package:xterm2/xterm.dart';

/// Plain text of the **bottom** [lines] rows of what is currently on screen.
///
/// This is the input to the third status source. It reads the *active* buffer,
/// so a full-screen TUI agent (Codex, and Claude Code outside `--no-alt-screen`)
/// is read from the alternate buffer it is actually drawing into — unlike
/// scrollback persistence, which deliberately only encodes the main buffer.
///
/// Only the bottom of the screen is returned, and that is a correctness
/// decision rather than an optimisation: an approval prompt is a *live* control
/// at the bottom of a TUI, while the same words scrolled up are history. Reading
/// the whole buffer would make "do you want to proceed?" from ten minutes ago
/// indistinguishable from the one waiting for an answer now.
///
/// Styling is dropped — matching runs on characters, not colours — and trailing
/// blank rows are trimmed so a half-empty viewport does not push the real
/// content out of the window.
List<String> terminalTailLines(Terminal terminal, {int lines = 12}) {
  final buffer = terminal.buffer;
  final all = buffer.lines;
  var end = all.length;
  while (end > 0 && _isBlank(all[end - 1])) {
    end--;
  }
  if (end == 0) return const [];
  final start = end - lines < 0 ? 0 : end - lines;
  return [for (var i = start; i < end; i++) _plainText(all[i])];
}

bool _isBlank(BufferLine line) {
  for (var i = 0; i < line.length; i++) {
    if (line.getCodePoint(i) > 32) return false;
  }
  return true;
}

String _plainText(BufferLine line) {
  final out = StringBuffer();
  for (var i = 0; i < line.length; i++) {
    final code = line.getCodePoint(i);
    // A cell never written reads as 0; render it as a space so words on either
    // side of an erased gap do not run together into a false match.
    out.writeCharCode(code == 0 ? 32 : code);
  }
  return out.toString().trimRight();
}
