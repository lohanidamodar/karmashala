import 'dart:io';

import 'package:karmashala_agent_status/karmashala_agent_status.dart';
import 'package:karmashala_terminal_runtime/screen_reading.dart';
import 'package:xterm2/xterm.dart';

/// A captured agent screen replayed into a real xterm grid — the grid a pane
/// holds — whose menu highlight moves on ↓/↑ the way the agent's does
/// (measured in `live_prompt_probe_test.dart`), and which records every key
/// pressed into it and the option Enter confirmed.
class FixtureMenuScreen {
  FixtureMenuScreen._(this.terminal, this.marker);

  /// [fixture] from `test/features/agents/fixtures/`, cut at [fraction] of its
  /// bytes, or — without one — just before the capture's own teardown
  /// (`Session terminated, killing shell…`), which overwrites a menu row.
  ///
  /// Written into [into] — a live pane's own grid — when given.
  factory FixtureMenuScreen.fixture(
    String fixture, {
    required String marker,
    double? fraction,
    Terminal? into,
  }) {
    final bytes = File(
      'test/features/agents/fixtures/$fixture.raw',
    ).readAsStringSync();
    final teardown = bytes.indexOf('Session terminated');
    final end = fraction != null
        ? (bytes.length * fraction).round()
        : (teardown < 0 ? bytes.length : teardown);
    return FixtureMenuScreen.text(
      bytes.substring(0, end),
      marker: marker,
      into: into,
    );
  }

  /// A screen written as raw terminal output.
  factory FixtureMenuScreen.text(
    String output, {
    required String marker,
    Terminal? into,
  }) {
    final terminal = (into ?? Terminal(maxLines: 10000))..resize(120, 40);
    terminal.write(output);
    return FixtureMenuScreen._(terminal, marker);
  }

  final Terminal terminal;
  final String marker;

  /// Every write into the pane, in order.
  final List<String> sent = [];

  /// The option Enter confirmed, if it was pressed on one.
  String? confirmed;

  /// The pane as the app reads it for a menu.
  List<String> rows() => terminalTailLines(terminal, lines: kMenuScreenRows);

  bool press(String keys) {
    sent.add(keys);
    for (final m in RegExp(r'\x1b\[[AB]|\r').allMatches(keys)) {
      switch (m[0]) {
        case '\x1b[B':
          _move(1);
        case '\x1b[A':
          _move(-1);
        case '\r':
          final at = _markerRow();
          if (at != null) {
            final (row, column) = at;
            confirmed = _text(row)
                .substring(column + marker.length)
                .trim()
                .replaceFirst(RegExp(r'^\d+\.\s+'), '');
          }
      }
    }
    return true;
  }

  List<String> get _lines => [
    for (var i = 0; i < terminal.buffer.lines.length; i++) _text(i),
  ];

  String _text(int i) {
    final line = terminal.buffer.lines[i];
    final out = StringBuffer();
    for (var c = 0; c < line.length; c++) {
      final code = line.getCodePoint(c);
      out.writeCharCode(code == 0 ? 32 : code);
    }
    return out.toString().trimRight();
  }

  /// The lowest row whose first non-blank glyph is the marker and a space.
  (int, int)? _markerRow() {
    final lines = _lines;
    for (var i = lines.length - 1; i >= 0; i--) {
      final row = lines[i];
      final column = row.length - row.trimLeft().length;
      if (row.startsWith('$marker ', column)) return (i, column);
    }
    return null;
  }

  /// Moves the marker to the next option row in [step]'s direction, redrawing
  /// both rows with cursor moves as a TUI does. A move past the end is a no-op.
  void _move(int step) {
    final at = _markerRow();
    if (at == null) return;
    final (from, column) = at;
    final lines = _lines;
    final textColumn = column + marker.length + 1;
    bool isOption(String r) =>
        r.length > textColumn &&
        r.substring(0, textColumn).trim().isEmpty &&
        r[textColumn] != ' ';
    final to = from + step;
    if (to < 0 || to >= lines.length || !isOption(lines[to])) return;
    final blank = ' ' * marker.length;
    _redraw(from, lines[from].replaceRange(column, textColumn - 1, blank));
    _redraw(to, lines[to].replaceRange(column, textColumn - 1, marker));
  }

  void _redraw(int bufferRow, String text) {
    final screenRow = bufferRow - terminal.buffer.scrollBack + 1;
    terminal.write('\x1b[$screenRow;1H\x1b[2K$text');
  }
}
