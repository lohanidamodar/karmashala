import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

/// What the VT parser must make of a stream of code points, pinned character by
/// character.
///
/// `ByteConsumer.add` — the parser's front door — stopped using
/// `String.runes` and now decodes surrogate pairs itself, because
/// `runes.toList()` was 40-60% of the whole parse (see
/// `ingest_throughput_cost_test.dart` and the comment on `_toRunes`). That is a
/// correctness-sensitive rewrite of the one place every byte of every pane
/// passes through, so this file states the contract it has to keep: astral
/// characters, unpaired surrogates, combining marks, wide glyphs, and anything
/// cut in half by a chunk boundary.
///
/// Every expectation here was captured against the `String.runes`
/// implementation first and is unchanged by the rewrite — including the two
/// cases where the old behaviour is merely *defined* rather than ideal (a
/// surrogate pair split across two writes stays split), because a performance
/// change is not the place to alter what the terminal displays.
void main() {
  // `maxLines` above the 24-row default a `Terminal` starts at: the `Buffer` is
  // built from the view height it finds at construction, and a ring smaller
  // than that is left holding empty slots the cursor can still address.
  Terminal terminal() => Terminal(maxLines: 200)..resize(20, 4);

  List<int> codePoints(Terminal terminal, {int row = 0, int count = 6}) {
    final line = terminal.buffer.lines[row];
    return [for (var x = 0; x < count; x++) line.getCodePoint(x)];
  }

  group('code points reach the buffer intact', () {
    test('plain ASCII', () {
      final t = terminal()..write('abc');
      expect(t.buffer.lines[0].getText(0, 3), 'abc');
    });

    test('an astral character written whole is one wide cell', () {
      // U+1F600 GRINNING FACE: a surrogate pair in UTF-16 and two columns wide.
      final t = terminal()..write('a\u{1F600}b');
      expect(codePoints(t), [
        'a'.codeUnitAt(0),
        0x1F600,
        // The trailing half of a double-width glyph is deliberately empty.
        0,
        'b'.codeUnitAt(0),
        0,
        0,
      ]);
    });

    test('an unpaired lead surrogate passes through as itself', () {
      final t = terminal()..write('a${String.fromCharCode(0xD83D)}b');
      expect(codePoints(t), [
        'a'.codeUnitAt(0),
        0xD83D,
        'b'.codeUnitAt(0),
        0,
        0,
        0,
      ]);
    });

    test('an unpaired trail surrogate passes through as itself', () {
      final t = terminal()..write('a${String.fromCharCode(0xDE00)}b');
      expect(codePoints(t), [
        'a'.codeUnitAt(0),
        0xDE00,
        'b'.codeUnitAt(0),
        0,
        0,
        0,
      ]);
    });

    test('a lead surrogate at the very end of a chunk is not held back', () {
      // The halves arrive in different writes, so neither one can see the
      // other. Both implementations emit two lone surrogates rather than
      // buffering the first — the app's own chunked UTF-8 decoder is what stops
      // a character being split here in the first place.
      final t = terminal()
        ..write('a${String.fromCharCode(0xD83D)}')
        ..write('${String.fromCharCode(0xDE00)}b');
      expect(codePoints(t), [
        'a'.codeUnitAt(0),
        0xD83D,
        0xDE00,
        'b'.codeUnitAt(0),
        0,
        0,
      ]);
    });

    test('a combining mark keeps its own cell', () {
      final t = terminal()..write('e\u0301f');
      expect(codePoints(t), [
        'e'.codeUnitAt(0),
        0x0301,
        'f'.codeUnitAt(0),
        0,
        0,
        0,
      ]);
    });

    test('a double-width CJK glyph takes two columns', () {
      final t = terminal()..write('a\u4f60b');
      expect(codePoints(t), [
        'a'.codeUnitAt(0),
        0x4f60,
        0,
        'b'.codeUnitAt(0),
        0,
        0,
      ]);
    });
  });

  group('sequences cut in half by a chunk boundary', () {
    test('a CSI split across two writes still applies once', () {
      final whole = terminal()..write('\x1b[31mred');
      final split = terminal()
        ..write('\x1b[3')
        ..write('1mred');
      expect(split.buffer.lines[0].getText(0, 3), 'red');
      expect(
        split.buffer.lines[0].getForeground(0),
        whole.buffer.lines[0].getForeground(0),
        reason: 'the rollback path has to reassemble the sequence exactly',
      );
    });

    test('a bare ESC at the end of a chunk waits for the rest', () {
      final t = terminal()
        ..write('ab\x1b')
        ..write('[2Dxy');
      // ESC [ 2 D moves the cursor two columns left, so `xy` overwrites `ab`.
      expect(t.buffer.lines[0].getText(0, 2), 'xy');
    });

    test('an OSC title split across three writes arrives whole', () {
      String? title;
      final t = terminal()..onTitleChange = (value) => title = value;
      t
        ..write('\x1b]0;half')
        ..write(' a ')
        ..write('title\x07');
      expect(title, 'half a title');
    });

    test('an astral character inside an OSC payload survives', () {
      String? title;
      final t = terminal()..onTitleChange = (value) => title = value;
      t.write('\x1b]0;done \u{1F600}\x07');
      expect(title, 'done \u{1F600}');
    });
  });

  test('a long mixed stream reads the same however it is chunked', () {
    // One write with every case in it at once, and a second with the same text
    // delivered a character at a time — so every escape sequence in it is
    // split from its parameters and the rollback path runs on all of them.
    const source = 'build \u{1F680} ok\r\n\x1b[32mpass\x1b[0m \u4f60\u597d e\u0301\r\n';
    final whole = Terminal(maxLines: 200)
      ..resize(30, 4)
      ..write(source);
    final dribbled = Terminal(maxLines: 200)..resize(30, 4);
    for (final rune in source.runes) {
      dribbled.write(String.fromCharCode(rune));
    }
    expect(dribbled.buffer.getText(), whole.buffer.getText());
  });
}
