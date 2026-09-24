import 'package:flutter_test/flutter_test.dart';
import 'package:xterm2/xterm.dart';

/// Claude Code draws inline: its live region starts at the cursor and runs
/// [_region] rows below it, and every redraw is relative — down to the region's
/// last row, erase upward, draw, park at the top again. So after a resize the
/// rows below the cursor must still be the rows it drew, or the redraw erases
/// the wrong ones and the old frame survives beside the new (2026-09-24,
/// `resizes.log` of an agent pane flipping 49 → 54 → 50 rows twenty times).
const _region = 8;

String _frame(String tag) => [
  for (var i = 0; i < _region; i++) '$tag row $i',
].join('\r\n');

/// The redraw the recording shows: `CSI n B`, `CSI 2K CSI 1A` up the region,
/// the new frame, and `CSI n A` back to its top.
String _redraw(String tag) =>
    '\x1b[${_region - 1}B'
    '${'\x1b[2K\x1b[1A' * (_region - 1)}\x1b[2K\r'
    '${_frame(tag)}'
    '\x1b[${_region - 1}A\r';

List<String> _allLines(Terminal terminal) => [
  for (var i = 0; i < terminal.buffer.lines.length; i++)
    terminal.buffer.lines[i].getText().trimRight(),
];

void main() {
  late Terminal terminal;

  setUp(() {
    terminal = Terminal(maxLines: 1000)..resize(80, 30);
    for (var i = 0; i < 40; i++) {
      terminal.write('history $i\r\n');
    }
    terminal.write('${_frame('v1')}\x1b[${_region - 1}A\r');
  });

  void expectIntact(String tag) {
    final lines = _allLines(terminal);
    for (var i = 0; i < 40; i++) {
      expect(
        lines.where((l) => l == 'history $i'),
        hasLength(1),
        reason: 'history $i was lost or duplicated:\n${lines.join('\n')}',
      );
    }
    expect(lines.where((l) => l.startsWith('v1 ')), isEmpty,
        reason: 'the old frame survived the redraw:\n${lines.join('\n')}');
    final bottom = lines.sublist(lines.length - terminal.viewHeight);
    final drawn = [for (var i = 0; i < _region; i++) '$tag row $i'];
    final at = bottom.indexOf(drawn.first);
    expect(at, isNot(-1), reason: bottom.join('\n'));
    expect(bottom.sublist(at, at + _region), drawn);
    expect(terminal.buffer.cursorY, at, reason: 'parked at the region top');
  }

  test('shrinking the height keeps the rows drawn below the cursor', () {
    terminal.resize(80, 25);
    terminal.write(_redraw('v2'));
    expectIntact('v2');
  });

  test('shrinking and growing back keeps the region and the history', () {
    terminal.resize(80, 25);
    terminal.resize(80, 30);
    terminal.write(_redraw('v2'));
    expectIntact('v2');
  });

  test('a height that flips back and forth, as the log shows, stays intact', () {
    for (final rows in [25, 26, 30, 25, 26, 30, 25, 30]) {
      terminal.resize(80, rows);
      terminal.write(_redraw('v$rows'));
    }
    expectIntact('v30');
  });
}
