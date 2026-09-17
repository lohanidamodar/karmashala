import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/terminal/data/scrollback_codec.dart';
import 'package:xterm2/xterm.dart';

/// Stored scrollback is read back into a pane of whatever width the window has
/// by then. A line the terminal wrapped has to come back as one line, or every
/// later width shows it broken where the old one happened to end.

Terminal blank(int width, {int height = 8}) =>
    Terminal(maxLines: 5000)..resize(width, height);

/// Every row, trailing blank rows dropped.
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

List<bool> wrapsOf(Terminal terminal) {
  final lines = terminal.mainBuffer.lines;
  return [for (var i = 0; i < rowsOf(terminal).length; i++) lines[i].isWrapped];
}

/// [logical] as a terminal [width] columns wide soft-wraps it.
List<String> wrapped(Iterable<String> logical, int width) => [
  for (final line in logical)
    if (line.isEmpty)
      ''
    else
      for (var at = 0; at < line.length; at += width)
        line.substring(at, (at + width).clamp(0, line.length)).trimRight(),
];

String prose(int index, int length) {
  final buffer = StringBuffer('line$index:');
  var n = 0;
  while (buffer.length < length) {
    buffer.write(String.fromCharCode(0x61 + (index + n++) % 26));
  }
  return buffer.toString().substring(0, length);
}

void main() {
  final logical = [
    for (var i = 0; i < 30; i++) prose(i, i.isEven ? 25 + i * 6 : 9),
  ];

  Terminal source(int width) {
    final terminal = blank(width);
    for (final line in logical) {
      terminal.write('$line\r\n');
    }
    return terminal;
  }

  test('a line the terminal wrapped is stored as one line', () {
    final terminal = blank(40)..write('${'x' * 100}\r\nshort\r\n');
    expect(rowsOf(terminal), hasLength(4));
    expect('\r\n'.allMatches(encodeScrollback(terminal)), hasLength(1));
  });

  test('a restore at the same width gives the same rows, still wrapped', () {
    final saved = source(40);
    final restored = blank(40)..write(encodeScrollback(saved));
    expect(rowsOf(restored), rowsOf(saved));
    expect(wrapsOf(restored), wrapsOf(saved));
  });

  test('a restore into a narrower pane wraps each line at that width', () {
    final restored = blank(31)..write(encodeScrollback(source(120)));
    expect(rowsOf(restored), wrapped(logical, 31));
  });

  test('a restore into a wider pane joins what the old width had split', () {
    final restored = blank(150)..write(encodeScrollback(source(40)));
    expect(rowsOf(restored), wrapped(logical, 150));
  });

  test('restored lines go on reflowing when the pane is resized', () {
    final restored = blank(40)..write(encodeScrollback(source(40)));
    restored.resize(97, 8);
    expect(rowsOf(restored), wrapped(logical, 97));
    restored.resize(23, 8);
    expect(rowsOf(restored), wrapped(logical, 23));
  });

  test('styles survive the join between two rows of one line', () {
    final saved = blank(20)
      ..write('\x1b[31m${'r' * 30}\x1b[32m${'g' * 30}\x1b[0m\r\n');
    final restored = blank(20)..write(encodeScrollback(saved));
    for (var y = 0; y < 3; y++) {
      for (var x = 0; x < 20; x++) {
        expect(
          restored.mainBuffer.lines[y].getForeground(x),
          saved.mainBuffer.lines[y].getForeground(x),
          reason: 'foreground at row $y, cell $x',
        );
      }
    }
  });

  test('a wide glyph pushed onto the next row comes back in one piece', () {
    final saved = blank(10)..write('abcdefghi\u{1F600}jkl\r\n');
    expect(rowsOf(saved), ['abcdefghi', '\u{1F600}jkl']);
    final encoded = encodeScrollback(saved);

    expect(rowsOf(blank(10)..write(encoded)), rowsOf(saved));
    expect(rowsOf(blank(30)..write(encoded)), ['abcdefghi\u{1F600}jkl']);
  });

  test('a wrapped row whose first half was erased stays its own row', () {
    // The flag outlives the text it continued: joining these would pull the
    // second row up into the gap.
    final saved = blank(20)..write('${'a' * 30}\x1b[1;11H\x1b[K\x1b[2;11H\r\n');
    expect(rowsOf(saved), ['a' * 10, 'a' * 10]);
    expect(saved.mainBuffer.lines[1].isWrapped, isTrue);

    final restored = blank(20)..write(encodeScrollback(saved));
    expect(rowsOf(restored), rowsOf(saved));
  });

  test('the byte cap still counts every separator it writes', () {
    final saved = source(40);
    final whole = encodeScrollback(saved, maxBytes: 1 << 30);
    for (final cap in [whole.length, whole.length - 1, 900, 300, 120]) {
      final capped = encodeScrollback(saved, maxBytes: cap);
      expect(capped.length, lessThanOrEqualTo(cap), reason: 'cap $cap');
      expect(whole.endsWith(capped), isTrue, reason: 'cap $cap keeps a tail');
    }
  });
}
