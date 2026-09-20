import 'package:xterm2/xterm.dart';

/// Plain text of the **bottom** [lines] rows of the *active* buffer — an
/// approval prompt is live there, while the same words scrolled up are
/// history.
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

/// How many lines of [terminal]'s buffer have anything on them, scrollback
/// included. [stopAt] bounds the walk, since callers only compare a threshold.
int nonBlankLineCount(Terminal terminal, {int? stopAt}) {
  final lines = terminal.buffer.lines;
  var count = 0;
  for (var i = 0; i < lines.length; i++) {
    if (stopAt != null && count >= stopAt) break;
    if (!_isBlank(lines[i])) count++;
  }
  return count;
}
