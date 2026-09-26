import 'dart:io';

import 'package:xterm2/core.dart';

/// The bottom [lines] non-blank-trailing rows of [terminal], blank cells as
/// spaces — what a pane or the session host reads a screen as.
List<String> terminalTailLines(Terminal terminal, {int lines = 12}) {
  final all = terminal.buffer.lines;
  var end = all.length;
  while (end > 0 && _text(all[end - 1]).trim().isEmpty) {
    end--;
  }
  final start = end - lines < 0 ? 0 : end - lines;
  return [for (var i = start; i < end; i++) _text(all[i])];
}

String _text(BufferLine line) {
  final out = StringBuffer();
  for (var i = 0; i < line.length; i++) {
    final code = line.getCodePoint(i);
    out.writeCharCode(code == 0 ? 32 : code);
  }
  return out.toString().trimRight();
}

/// A captured PTY stream from the app's fixtures, cut at [fraction] of its
/// bytes, laid out by a real VT parser at [columns]×[rows].
Terminal fixtureScreen(
  String fixture, {
  double fraction = 1.0,
  int columns = 120,
  int rows = 30,
}) {
  final bytes = File(
    '../../app/test/features/agents/fixtures/$fixture.raw',
  ).readAsStringSync();
  return Terminal(maxLines: 10000)
    ..resize(columns, rows)
    ..write(bytes.substring(0, (bytes.length * fraction).round()));
}
