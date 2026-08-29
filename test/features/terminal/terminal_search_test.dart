import 'package:chitragupta/src/features/terminal/domain/terminal_search.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

Terminal terminalWith(String data, {int width = 40}) {
  final terminal = Terminal(maxLines: 100)..resize(width, 10);
  terminal.write(data);
  return terminal;
}

TerminalLineText lineOf(String text, {int width = 40}) =>
    lineTextOf(terminalWith(text, width: width).buffer.lines[0]);

void main() {
  test('finds every occurrence on a line, case-insensitively by default', () {
    final matches = searchLines([lineOf('Error and error and ERROR')], 'error');
    expect(matches.length, 3);
    expect(matches[0].startColumn, 0);
    expect(matches[0].endColumn, 5);
    expect(matches[1].startColumn, 10);
    expect(matches[2].startColumn, 20);
  });

  test('caseSensitive narrows the result', () {
    final line = [lineOf('Error and error')];
    final matches = searchLines(line, 'error', caseSensitive: true);
    expect(matches.length, 1);
    expect(matches.single.startColumn, 10);
  });

  test('an empty query and a query with no hits find nothing', () {
    expect(searchLines([lineOf('hello')], ''), isEmpty);
    expect(searchLines([lineOf('hello')], 'zzz'), isEmpty);
  });

  test('overlapping candidates advance past each match', () {
    final matches = searchLines([lineOf('aaaa')], 'aa');
    expect(matches.map((m) => m.startColumn), [0, 2]);
  });

  test('reports the line index of each match', () {
    final terminal = terminalWith('alpha\r\nbeta\r\nalpha\r\n');
    final lines = [
      for (var i = 0; i < 3; i++) lineTextOf(terminal.buffer.lines[i]),
    ];
    expect(searchLines(lines, 'alpha').map((m) => m.line), [0, 2]);
  });

  test('columns are cell columns, so a wide glyph before a match shifts it', () {
    final matches = searchLines([lineOf('你hit')], 'hit');
    expect(matches.single.startColumn, 2);
    expect(matches.single.endColumn, 5);
  });

  test('a match containing a wide glyph spans its full cell width', () {
    final matches = searchLines([lineOf('a你b')], '你b');
    expect(matches.single.startColumn, 1);
    expect(matches.single.endColumn, 4);
  });

  test('empty cells read as spaces so a gap does not break the column map', () {
    // Write 'ab', jump the cursor to column 6, write 'cd'.
    final line = lineOf('ab\x1b[6Gcd');
    expect(line.text.startsWith('ab   cd'), isTrue);
    expect(searchLines([line], 'cd').single.startColumn, 5);
  });

  test('a blank line yields empty text and no matches', () {
    final line = lineOf('');
    expect(line.text, isEmpty);
    expect(searchLines([line], 'x'), isEmpty);
  });

  test('trailing blanks are trimmed so a query cannot match past the text', () {
    final line = lineOf('hi');
    expect(line.text, 'hi');
    expect(searchLines([line], 'hi  '), isEmpty);
  });
}
