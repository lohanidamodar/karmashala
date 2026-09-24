import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/terminal/presentation/terminal_copy_text.dart';
import 'package:xterm2/xterm.dart';

void main() {
  test('each copied line loses the spaces a program padded it with', () {
    final terminal = Terminal()..resize(40, 5);
    // Real spaces, not blank cells: a TUI pads its rows out like this.
    terminal.write('first line          \r\nsecond   \r\n  third');
    final all = BufferRangeLine(CellOffset(0, 0), CellOffset(40, 2));

    expect(
      terminalCopyText(terminal.buffer, all),
      'first line\nsecond\n  third',
      reason: 'leading indentation is content and stays',
    );
  });

  test('the gap a program left by moving the cursor still copies', () {
    final terminal = Terminal()..resize(40, 5);
    terminal.write('User declined\x1b[17Gto answer');
    final row = BufferRangeLine(CellOffset(0, 0), CellOffset(40, 0));

    expect(terminalCopyText(terminal.buffer, row), 'User declined   to answer');
  });
}
