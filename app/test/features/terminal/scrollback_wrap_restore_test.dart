import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_terminal_runtime/instances.dart';
import 'package:karmashala_terminal_runtime/scrollback.dart';
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

  group('a TUI drawn to the full width, restored into a narrower pane', () {
    // Claude Code's input box as it reaches a pane: rule, prompt, rule, footer,
    // each a row of the width it was drawn at, repainted in place by erasing
    // the rows it drew (cursor up, erase line) and drawing them again.
    String rule(int width) => '\x1b[38;2;136;136;136m${'─' * width}\x1b[0m';
    String frame(int width, String prompt) =>
        '${rule(width)}\r\n❯ $prompt\r\n${rule(width)}\r\n'
        '\x1b[38;2;153;153;153m  manual mode on · ? for shortcuts\x1b[0m';
    const erase = '\x1b[2K\x1b[1A\x1b[2K\x1b[1A\x1b[2K\x1b[1A\x1b[2K\x1b[G';

    Terminal claude(int width) {
      final terminal = blank(width, height: 12)
        ..write('● Both agents have finished.\r\n\r\n');
      terminal.write(frame(width, ''));
      for (final typed in ['are', 'are they', 'are they done yet?']) {
        terminal.write('$erase${frame(width, typed)}');
      }
      return terminal;
    }

    test('the footer is drawn once, each rule on one row', () {
      final saved = claude(120);
      expect(rowsOf(saved), [
        '● Both agents have finished.',
        '',
        '─' * 120,
        '❯ are they done yet?',
        '─' * 120,
        '  manual mode on · ? for shortcuts',
      ]);

      final restored = blank(48)..write(encodeScrollback(saved));
      expect(rowsOf(restored), [
        '● Both agents have finished.',
        '',
        '─' * 48,
        '❯ are they done yet?',
        '─' * 48,
        '  manual mode on · ? for shortcuts',
      ]);
    });

    test('a rule that ran on into the next row still restores as one', () {
      // ConPTY sends a full-width row with no line break after it, so the
      // terminal holds the prompt and footer as continuations of the rules.
      final saved = blank(120, height: 12)
        ..write(
          '${rule(120)}❯ are they done yet?\r\n${rule(120)}'
          '  manual mode on · ? for shortcuts',
        );
      expect(saved.mainBuffer.lines[1].isWrapped, isTrue);

      final restored = blank(48)..write(encodeScrollback(saved));
      expect(rowsOf(restored), [
        '─' * 48,
        '❯ are they done yet?',
        '─' * 48,
        '  manual mode on · ? for shortcuts',
      ]);
    });

    test('at the width it was saved at, it comes back cell for cell', () {
      final saved = claude(60);
      final restored = blank(60, height: 12)..write(encodeScrollback(saved));
      expect(rowsOf(restored), rowsOf(saved));
      expect(wrapsOf(restored), wrapsOf(saved));
    });

    test('a row padded out with spaces gains no blank rows', () {
      final saved = blank(120)
        ..write('It took about 65 seconds.${' ' * 95}\r\nnext\r\n');
      final restored = blank(40)..write(encodeScrollback(saved));
      expect(rowsOf(restored), ['It took about 65 seconds.', 'next']);
    });

    test('nor does one padded out and run on into the next', () {
      final saved = blank(120)
        ..write('It took about 65 seconds.${' ' * 95}next\r\n');
      final restored = blank(40)..write(encodeScrollback(saved));
      expect(rowsOf(restored), ['It took about 65 seconds.', 'next']);
    });

    test('text that reaches the last column still wraps whole', () {
      final text = prose(3, 120);
      final saved = blank(120)..write('$text\r\nnext\r\n');
      final restored = blank(50)..write(encodeScrollback(saved));
      expect(rowsOf(restored), [
        ...wrapped([text], 50),
        'next',
      ]);
    });

    group('captured: an answered question above the box, 348 wide', () {
      // A two-column block: the header padded out to the edge, its first item
      // a continuation, the second a line of its own.
      Terminal captured(Terminal terminal) {
        const header = "● User answered Claude's questions:";
        const second = '     · Which fruits do you like? → Pear';
        terminal.write(
          '$header${' ' * (348 - header.length)}'
          '  └ · Which color do you pick? → Red\r\n'
          '$second${' ' * (348 - second.length)}\r\n\r\n'
          '${rule(348)}❯ \r\n${rule(348)}'
          '\x1b[38;2;153;153;153m  ⏸ manual mode on · ? for shortcuts\x1b[0m',
        );
        return terminal;
      }

      final at87 = [
        "● User answered Claude's questions:",
        '  └ · Which color do you pick? → Red',
        '     · Which fruits do you like? → Pear',
        '',
        '─' * 87,
        '❯',
        '─' * 87,
        '  ⏸ manual mode on · ? for shortcuts',
      ];

      PaneTerminal pane(int width) =>
          PaneTerminal(maxLines: 5000, settle: Duration.zero)
            ..resizeNow(width, 20);

      test('restored into a wider grid and then narrowed', () {
        final encoded = encodeScrollback(captured(blank(348, height: 20)));
        final restored = pane(122)..write(encoded);
        restored.resize(87, 20);
        expect(rowsOf(restored), at87);
      });

      test('narrowed live, then saved and restored', () {
        final live = captured(pane(348))..resize(87, 20);
        expect(rowsOf(live), at87);
        final restored = blank(87, height: 20)..write(encodeScrollback(live));
        expect(rowsOf(restored), at87);
      });

      test('the leftover of a cut rule saved before is dropped', () {
        // What an older save holds: rows as wide as the pane they came from,
        // read back narrower, so each rule's rest ran onto rows of its own.
        final old = blank(87, height: 20)
          ..write(
            '${'─' * 152}\r\n❯ \r\n${'─' * 152}\r\n'
            '  ⏸ manual mode on · ? for shortcuts',
          );
        expect(rowsOf(old), hasLength(6));
        final restored = blank(87, height: 20)..write(encodeScrollback(old));
        expect(rowsOf(restored), at87.sublist(4));
      });
    });

    test('a rule after text that fills the row starts a row of its own', () {
      final saved = blank(30)..write('${'a' * 20}${'═' * 10}\r\n');
      final restored = blank(20)..write(encodeScrollback(saved));
      expect(rowsOf(restored), ['a' * 20, '═' * 10]);
    });
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
