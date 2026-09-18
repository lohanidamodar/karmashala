import 'package:flutter_test/flutter_test.dart';
import 'package:xterm2/xterm.dart';

/// Pins the xterm2 the app is built against to one that carries the fork's
/// divergence 9: a line that narrows forgets the cells it lost. Without it, a
/// row a TUI repainted while the pane was narrow shows the tail of what it held
/// while wide as soon as the pane widens — and in the scrollback, for good.
///
/// Add as `test/features/terminal/resize_stale_cells_test.dart` in the commit
/// that moves `pubspec.yaml`'s `xterm2` ref; it fails against febca4d.
List<String> rowsOf(Terminal terminal) {
  final lines = terminal.mainBuffer.lines;
  final out = [
    for (var i = 0; i < lines.length; i++) lines[i].toString().trimRight(),
  ];
  while (out.isNotEmpty && out.last.isEmpty) {
    out.removeLast();
  }
  return out;
}

void main() {
  test('a row repainted while narrow shows nothing old when widened', () {
    final terminal = Terminal(maxLines: 1000)..resize(100, 10);
    const long =
        'A pass over the other states: devices connected, emulator '
        'starting, errors, and Wi-Fi pairing.';
    terminal.write('$long\r\n');

    terminal.resize(60, 10);
    // The TUI's answer to SIGWINCH: up over its region, erase, repaint.
    terminal.write("\x1b[1A\r\x1b[JWhat's wrong in your screenshot:\r\n");
    terminal.write('\r\n' * 20);

    terminal.resize(100, 10);
    expect(rowsOf(terminal), [
      long.substring(0, 60),
      "What's wrong in your screenshot:",
    ]);
  });

  test('the alternate screen hides what it held before it narrowed', () {
    final terminal = Terminal(maxLines: 1000)..resize(80, 5);
    terminal.write('\x1b[?1049h${'y' * 70}RIGHT-EDGE');
    terminal.resize(40, 5);
    terminal.write('\x1b[H\x1b[2Kleft');
    terminal.resize(80, 5);
    expect(terminal.altBuffer.lines[0].toString().trimRight(), 'left');
  });
}
