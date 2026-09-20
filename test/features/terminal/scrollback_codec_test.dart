import 'package:karmashala/src/features/terminal/data/scrollback_codec.dart';
import 'package:karmashala_terminal_core/pane_lifecycle.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm2/xterm.dart';

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

  test('the default cap is the durable budget, not the live one', () {
    expect(kDurableScrollbackMaxLines, 2000);
    expect(kDurableScrollbackMaxBytes, 256 * 1024);
    expect(kLiveScrollbackMaxLines, 10000);

    // A pane holding more than the durable window still persists only the
    // durable window: what is kept in RAM and what is written to SQLite are
    // separate budgets, and the encoder answers to the second one.
    final source = Terminal(maxLines: kLiveScrollbackMaxLines)
      ..resize(40, 10)
      ..write([for (var i = 0; i < 2500; i++) 'line$i\r\n'].join());
    final encoded = encodeScrollback(source, maxBytes: 1 << 30);

    expect('\n'.allMatches(encoded).length + 1, kDurableScrollbackMaxLines);
    expect(encoded, contains('line2499'));
    expect(encoded, isNot(contains('line499\x1b')));
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

  // --- what a save costs ------------------------------------------------------

  /// The byte cap as it was originally written: encode every candidate line,
  /// then drop one leading line and re-join until the result fits.
  ///
  /// Kept here as the reference the fast path must agree with, byte for byte.
  /// It is also why the fast path exists — it is quadratic in the overshoot,
  /// and it cost 121 ms to 2 588 ms per pane per autosave tick (Loop 84,
  /// `tool/benchmark/scrollback_save_bench.dart`).
  String referenceEncode(Terminal terminal, {required int maxBytes}) {
    final all = encodeScrollback(terminal, maxBytes: 1 << 30);
    if (all.isEmpty) return '';
    final encoded = all.split('\r\n');
    var result = encoded.join('\r\n');
    var first = 0;
    while (result.length > maxBytes && first < encoded.length - 1) {
      first++;
      result = encoded.sublist(first).join('\r\n');
    }
    return result.length > maxBytes ? '' : result;
  }

  test('the byte cap keeps exactly the lines the original loop kept', () {
    final source = terminalWith(
      [
        for (var i = 0; i < 400; i++)
          '\x1b[38;5;${i % 256}mline $i with some content\x1b[0m\r\n',
      ].join(),
    );
    // Sweep the cap across the whole range, including both ends: an exact-fit
    // boundary is where an off-by-one in the running total would show.
    final full = encodeScrollback(source, maxBytes: 1 << 30).length;
    for (final maxBytes in [
      0,
      1,
      40,
      41,
      42,
      500,
      full ~/ 3,
      full ~/ 2,
      full - 1,
      full,
      full + 1,
    ]) {
      expect(
        encodeScrollback(source, maxBytes: maxBytes),
        referenceEncode(source, maxBytes: maxBytes),
        reason: 'maxBytes=$maxBytes',
      );
    }
  });

  test('a save encodes what it stores, not what it considered', () {
    // A pane full of per-cell 24-bit colour: ~4 KB of SGR per line, so the
    // 256 KB cap is met long before the 2 000-line window is.
    final source = Terminal(maxLines: kLiveScrollbackMaxLines)..resize(200, 50);
    for (var row = 0; row < 400; row++) {
      final cells = StringBuffer();
      for (var x = 0; x < 200; x++) {
        cells.write('\x1b[38;2;${x % 256};${(x * 7) % 256};${row % 256}m#');
      }
      source.write('$cells\r\n');
    }

    final stats = encodeScrollbackWithStats(source);
    expect(stats.encoded.length, lessThanOrEqualTo(kDurableScrollbackMaxBytes));
    // The window offers 2 000 lines; the budget is spent after a few dozen.
    // Encoding all 2 000 and throwing 97% away is the bug this pins.
    expect(stats.linesEncoded, lessThan(200));
    expect(
      stats.linesEncoded,
      '\r\n'.allMatches(stats.encoded).length + 1,
      reason: 'every line encoded is a line stored',
    );
  });
}
