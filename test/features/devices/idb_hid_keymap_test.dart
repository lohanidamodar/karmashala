import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/devices/data/idb_hid_keymap.dart';

/// Reads keystrokes back into the text they type, so a round-trip can assert
/// on the string a person would see in the field rather than on 38 integers.
///
/// Built by inverting the public API over the printable ASCII range: it is the
/// map's own opinion, so it proves nothing about individual codes — the tables
/// below do that — but it does prove the sequence is order-preserving and
/// one-keystroke-per-character.
String _render(List<HidKeystroke> strokes) {
  final inverse = <HidKeystroke, String>{
    for (var code = 0x20; code <= 0x7e; code++)
      ?hidKeystrokeFor(String.fromCharCode(code)): String.fromCharCode(code),
  };
  return strokes.map((stroke) => inverse[stroke] ?? '\u{fffd}').join();
}

void main() {
  group('the letter block', () {
    test('a..z are 4..29, unshifted and in order', () {
      // The single most load-bearing claim in the file: an off-by-one here
      // types `bcd` for `abc` and every test above this one still passes.
      for (var i = 0; i < 26; i++) {
        final letter = String.fromCharCode('a'.codeUnitAt(0) + i);

        expect(
          hidKeystrokeFor(letter),
          HidKeystroke(4 + i),
          reason: 'lowercase $letter',
        );
      }
    });

    test('A..Z share the code and add shift', () {
      // There is no usage code for a capital; the only difference between `a`
      // and `A` on the wire is the shift bracket.
      for (var i = 0; i < 26; i++) {
        final lower = String.fromCharCode('a'.codeUnitAt(0) + i);
        final upper = lower.toUpperCase();
        final stroke = hidKeystrokeFor(upper);

        expect(stroke?.usageCode, hidKeystrokeFor(lower)?.usageCode);
        expect(stroke?.shift, isTrue, reason: 'uppercase $upper');
      }
    });
  });

  group('the digit row', () {
    test('1..9 are 30..38 and 0 wraps to 39', () {
      for (var digit = 1; digit <= 9; digit++) {
        expect(hidKeystrokeFor('$digit'), HidKeystroke(29 + digit));
      }

      // The trap: `0` sits at the end of the row, not the start, so any
      // arithmetic from the digit's value types `9` when asked for `0`.
      expect(hidKeystrokeFor('0'), const HidKeystroke(39));
    });

    test('the shifted row is the symbols above the digits', () {
      const shifted = {
        '!': 30,
        '@': 31,
        '#': 32,
        '\$': 33,
        '%': 34,
        '^': 35,
        '&': 36,
        '*': 37,
        '(': 38,
        ')': 39,
      };

      shifted.forEach((symbol, code) {
        expect(
          hidKeystrokeFor(symbol),
          HidKeystroke(code, shift: true),
          reason: symbol,
        );
      });
    });
  });

  group('punctuation', () {
    test('unshifted keys carry their usage-table codes', () {
      // 50 is deliberately absent: it is the non-US `#`/`~` key, which is why
      // `\` (49) and `;` (51) are not adjacent.
      const unshifted = {
        '-': 45,
        '=': 46,
        '[': 47,
        ']': 48,
        '\\': 49,
        ';': 51,
        "'": 52,
        '`': 53,
        ',': 54,
        '.': 55,
        '/': 56,
      };

      unshifted.forEach((character, code) {
        expect(
          hidKeystrokeFor(character),
          HidKeystroke(code),
          reason: character,
        );
      });
    });

    test('shifted keys reuse the same code', () {
      const shifted = {
        '_': 45,
        '+': 46,
        '{': 47,
        '}': 48,
        '|': 49,
        ':': 51,
        '"': 52,
        '~': 53,
        '<': 54,
        '>': 55,
        '?': 56,
      };

      shifted.forEach((character, code) {
        expect(
          hidKeystrokeFor(character),
          HidKeystroke(code, shift: true),
          reason: character,
        );
      });
    });
  });

  group('keys with no glyph', () {
    test('space, return, tab, backspace and escape are typable', () {
      // Return and Tab are typed rather than refused: submitting a search
      // field by sending its newline is the ordinary reason to type one.
      expect(hidKeystrokeFor(' '), const HidKeystroke(44));
      expect(hidKeystrokeFor('\n'), const HidKeystroke(40));
      expect(hidKeystrokeFor('\t'), const HidKeystroke(43));
      expect(hidKeystrokeFor('\b'), const HidKeystroke(42));
      expect(hidKeystrokeFor('\u001b'), const HidKeystroke(41));
    });

    test('a carriage return is refused, not turned into a second Return', () {
      // `\r` is almost always half a CRLF. Typing it would submit the form
      // twice; refusing tells the caller to normalise its line endings.
      expect(hidKeystrokeFor('\r'), isNull);
      expect(hidKeystrokesFor('line one\r\nline two'), isNull);
    });

    test('the modifier codes are the left-hand ones', () {
      expect(kHidLeftControl, 224);
      expect(kHidLeftShift, 225);
      expect(kHidLeftOption, 226);
      expect(kHidLeftCommand, 227);
    });
  });

  group('typing a string', () {
    test('a realistic line comes back as itself, one stroke per character', () {
      const line = r'Order #42: 3 x "Flat White" @ $4.50 — no, wait.';
      const typable = r'Order #42: 3 x "Flat White" @ $4.50 - no, wait.';

      final strokes = hidKeystrokesFor(typable);

      expect(strokes, isNotNull);
      expect(strokes!.length, typable.length);
      expect(_render(strokes), typable);
      // The em dash in [line] is exactly the kind of character a caller pastes
      // in without noticing, and it has no key.
      expect(hidKeystrokesFor(line), isNull);
    });

    test('the sequence is exact, shift and all', () {
      expect(hidKeystrokesFor('Hi, Bob!'), const [
        HidKeystroke(11, shift: true), // H
        HidKeystroke(12), // i
        HidKeystroke(54), // ,
        HidKeystroke(44), // space
        HidKeystroke(5, shift: true), // B
        HidKeystroke(18), // o
        HidKeystroke(5), // b
        HidKeystroke(30, shift: true), // !
      ]);
    });

    test('an empty string types nothing, and is not a refusal', () {
      // Distinct from null: there is nothing to type, which is a success.
      expect(hidKeystrokesFor(''), isEmpty);
    });
  });

  group('characters with no key', () {
    test('the whole string is refused rather than partly typed', () {
      // Typing `cafe` when the caller asked for `café` and reporting success
      // leaves the caller reasoning about a screen that does not exist. The
      // refusal hands the decision back.
      expect(hidKeystrokesFor('café'), isNull);
      expect(hidKeystrokesFor('東京'), isNull);
      expect(hidKeystrokesFor('ship it 🚢'), isNull);
      expect(hidKeystrokeFor('é'), isNull);
    });

    test('an emoji is one failed lookup, not two stray surrogates', () {
      // Iterating UTF-16 code units would test each half of the pair on its
      // own; neither half is in the map, so the answer would be right by
      // accident here and wrong for anything that mixed in a mapped half.
      expect('🚢'.length, 2);
      expect(hidKeystrokesFor('🚢'), isNull);
    });

    test('a multi-character string is not a character', () {
      expect(hidKeystrokeFor('ab'), isNull);
      expect(hidKeystrokeFor(''), isNull);
    });
  });
}
