import 'package:chitragupta/src/features/terminal/data/scrollback_codec.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

Terminal blank({int width = 40, int height = 10}) =>
    Terminal(maxLines: 5000)..resize(width, height);

Terminal terminalWith(String data, {int width = 40, int height = 10}) =>
    blank(width: width, height: height)..write(data);

/// Every cell of the first [lines] lines, as the tuple that defines what is on
/// screen. Comparing these is what makes "round-trips" mean something.
List<List<int>> cellsOf(Terminal terminal, int lines, int width) => [
  for (var y = 0; y < lines; y++)
    for (var x = 0; x < width; x++)
      [
        terminal.buffer.lines[y].getCodePoint(x),
        terminal.buffer.lines[y].getForeground(x),
        terminal.buffer.lines[y].getBackground(x),
        terminal.buffer.lines[y].getAttributes(x),
      ],
];

void main() {
  test('an empty buffer encodes to an empty string', () {
    expect(encodeScrollback(blank()), '');
  });

  test('plain text round-trips cell for cell', () {
    final source = terminalWith('hello\r\nworld\r\n');
    final restored = blank()..write(encodeScrollback(source));
    expect(cellsOf(restored, 2, 40), cellsOf(source, 2, 40));
  });

  test('named, bright, palette and rgb foreground colours round-trip', () {
    final source = terminalWith(
      '\x1b[31mred\x1b[0m \x1b[92mbright\x1b[0m '
      '\x1b[38;5;208mpal\x1b[0m \x1b[38;2;10;20;30mrgb\x1b[0m\r\n',
    );
    final restored = blank()..write(encodeScrollback(source));
    expect(cellsOf(restored, 1, 40), cellsOf(source, 1, 40));
  });

  test('named, bright, palette and rgb background colours round-trip', () {
    final source = terminalWith(
      '\x1b[41mbg\x1b[0m \x1b[102mbb\x1b[0m '
      '\x1b[48;5;99mbgpal\x1b[0m \x1b[48;2;1;2;3mbgrgb\x1b[0m\r\n',
    );
    final restored = blank()..write(encodeScrollback(source));
    expect(cellsOf(restored, 1, 40), cellsOf(source, 1, 40));
  });

  test('every attribute bit round-trips', () {
    final source = terminalWith(
      '\x1b[1mb\x1b[2mf\x1b[3mi\x1b[4mu\x1b[5mk'
      '\x1b[7mv\x1b[8mn\x1b[9ms\x1b[0m x\r\n',
    );
    final restored = blank()..write(encodeScrollback(source));
    expect(cellsOf(restored, 1, 40), cellsOf(source, 1, 40));
  });

  test('a double-width glyph round-trips into the same two cells', () {
    final source = terminalWith('a你b\r\n');
    final restored = blank()..write(encodeScrollback(source));
    expect(cellsOf(restored, 1, 40), cellsOf(source, 1, 40));
  });

  test('an interior gap restores as empty cells, not as spaces', () {
    final source = terminalWith('ab\x1b[6Gcd\r\n');
    final restored = blank()..write(encodeScrollback(source));
    expect(cellsOf(restored, 1, 40), cellsOf(source, 1, 40));
  });

  test('maxLines keeps the newest lines and drops the oldest', () {
    final source = terminalWith(
      [for (var i = 0; i < 50; i++) 'line$i\r\n'].join(),
    );
    final encoded = encodeScrollback(source, maxLines: 5);
    expect(encoded, contains('line49'));
    expect(encoded, isNot(contains('line44')));
    expect('\n'.allMatches(encoded).length, 4);
  });

  test('maxBytes drops whole leading lines, never a partial escape', () {
    final source = terminalWith(
      [for (var i = 0; i < 50; i++) '\x1b[31mline$i\x1b[0m\r\n'].join(),
    );
    final encoded = encodeScrollback(source, maxBytes: 120);
    expect(encoded.length, lessThanOrEqualTo(120));
    final restored = blank()..write(encoded);
    expect(
      restored.buffer.lines[0].getText().trim(),
      matches(RegExp(r'^line\d+$')),
    );
  });

  test(
    'lines are joined, so a restore does not gain a blank line each cycle',
    () {
      final source = terminalWith('a\r\nb\r\nc\r\n');
      final first = encodeScrollback(source);
      final restored = blank()..write(first);
      expect(encodeScrollback(restored), first);
    },
  );

  test('the alt buffer is not scrollback and is never encoded', () {
    final source = terminalWith('main content\r\n');
    // Switch to the alternate screen and write something else there.
    source.write('\x1b[?1049h');
    source.write('alt content\r\n');
    final encoded = encodeScrollback(source);
    expect(encoded, contains('main content'));
    expect(encoded, isNot(contains('alt content')));
  });

  test('trailing blank lines are dropped', () {
    final source = terminalWith('only\r\n\r\n\r\n');
    final encoded = encodeScrollback(source);
    expect(encoded, contains('only'));
    expect(encoded, isNot(contains('\n')), reason: 'one line, so no separator');
  });

  test('each encoded line is self-contained, so trimming is always safe', () {
    // The red opened on line 1 is what colours line 2. Restoring line 2 alone
    // must still produce red, or dropping leading lines would lose the style.
    final source = terminalWith('\x1b[31mred\r\nstill red\x1b[0m\r\n');
    final secondLine = encodeScrollback(source).split('\r\n')[1];
    final restored = blank()..write(secondLine);

    for (var x = 0; x < 40; x++) {
      expect(
        restored.buffer.lines[0].getCodePoint(x),
        source.buffer.lines[1].getCodePoint(x),
        reason: 'code point at cell $x',
      );
      expect(
        restored.buffer.lines[0].getForeground(x),
        source.buffer.lines[1].getForeground(x),
        reason: 'foreground at cell $x',
      );
    }
  });
}
