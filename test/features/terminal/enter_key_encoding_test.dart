import 'package:chitragupta/src/features/terminal/domain/enter_key_encoding.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/core.dart';

/// What a modified `Enter` actually puts on the wire.
///
/// Asserted as **bytes**, because bytes are the only thing the program in the
/// pane sees. Before this handler existed, every row below produced `[13]` —
/// which is why Claude Code's Shift+Enter simply submitted.
void main() {
  /// The exact bytes [key] with these modifiers writes to the PTY.
  List<int>? bytesFor(
    TerminalKey key, {
    bool shift = false,
    bool ctrl = false,
    bool alt = false,
    bool lineFeedMode = false,
  }) {
    final terminal = Terminal(maxLines: 100)..resize(80, 24);
    terminal.inputHandler = const ChitraguptaInputHandler();
    if (lineFeedMode) terminal.write('\x1b[20h');
    List<int>? written;
    terminal.onOutput = (data) => written = data.codeUnits;
    terminal.keyInput(key, shift: shift, ctrl: ctrl, alt: alt);
    return written;
  }

  group('Enter', () {
    test('plain Enter is still a bare carriage return', () {
      expect(bytesFor(TerminalKey.enter), [0x0D]);
    });

    test('plain Enter under line-feed mode still adds the line feed', () {
      // The package's own keytab owns this; the handler must not intercept it.
      expect(bytesFor(TerminalKey.enter, lineFeedMode: true), [0x0D, 0x0A]);
    });

    test('Shift+Enter is ESC CR, which is what inserts a newline', () {
      expect(bytesFor(TerminalKey.enter, shift: true), [0x1B, 0x0D]);
    });

    test('Ctrl+Enter is CSI 13 ; 5 u', () {
      expect(
        String.fromCharCodes(bytesFor(TerminalKey.enter, ctrl: true)!),
        '\x1b[13;5u',
      );
    });

    test('Alt+Enter is ESC CR — the meta prefix, as it always should have been', () {
      expect(bytesFor(TerminalKey.enter, alt: true), [0x1B, 0x0D]);
    });

    test('Ctrl+Shift+Enter carries both modifiers in the CSI-u parameter', () {
      expect(
        String.fromCharCodes(
          bytesFor(TerminalKey.enter, ctrl: true, shift: true)!,
        ),
        '\x1b[13;6u',
      );
    });

    test('Ctrl+Alt+Enter and Ctrl+Alt+Shift+Enter too', () {
      expect(
        String.fromCharCodes(
          bytesFor(TerminalKey.enter, ctrl: true, alt: true)!,
        ),
        '\x1b[13;7u',
      );
      expect(
        String.fromCharCodes(
          bytesFor(TerminalKey.enter, ctrl: true, alt: true, shift: true)!,
        ),
        '\x1b[13;8u',
      );
    });

    test('every modified Enter differs from plain Enter', () {
      final plain = bytesFor(TerminalKey.enter);
      for (final mods in [
        (shift: true, ctrl: false, alt: false),
        (shift: false, ctrl: true, alt: false),
        (shift: false, ctrl: false, alt: true),
        (shift: true, ctrl: true, alt: false),
      ]) {
        expect(
          bytesFor(
            TerminalKey.enter,
            shift: mods.shift,
            ctrl: mods.ctrl,
            alt: mods.alt,
          ),
          isNot(plain),
          reason: 'shift=${mods.shift} ctrl=${mods.ctrl} alt=${mods.alt}',
        );
      }
    });

    test('the numpad Enter is encoded identically', () {
      expect(bytesFor(TerminalKey.numpadEnter, shift: true), [0x1B, 0x0D]);
      expect(
        String.fromCharCodes(
          bytesFor(TerminalKey.numpadEnter, ctrl: true)!,
        ),
        '\x1b[13;5u',
      );
    });
  });

  group('everything else is left to the package', () {
    test('Ctrl+C is still the interrupt byte', () {
      expect(bytesFor(TerminalKey.keyC, ctrl: true), [0x03]);
    });

    test('a plain arrow key still gets its ordinary sequence', () {
      expect(
        String.fromCharCodes(bytesFor(TerminalKey.arrowUp)!),
        '\x1b[A',
      );
    });

    test('Tab and Backspace are untouched', () {
      expect(bytesFor(TerminalKey.tab), [0x09]);
      expect(bytesFor(TerminalKey.backspace), isNotNull);
    });
  });

  group('modifier-reporting probes', _prefixedSgrIsNotSgr);
}

/// A modifier-reporting *request* is not a colour change.
///
/// `CSI > 4 ; 2 m` (xterm's `modifyOtherKeys`) reached the vendored parser's SGR
/// handler, which ignored the `>` prefix and applied SGR 4 and SGR 2. Any
/// program that asked whether it could have real modifiers left the pane
/// underlined and faint. See `packages/xterm/VENDORED.md`.
void _prefixedSgrIsNotSgr() {
  test('a prefixed CSI m does not change the graphic rendition', () {
    for (final probe in ['\x1b[>4;2m', '\x1b[>4m', '\x1b[>1m', '\x1b[?4m']) {
      final terminal = Terminal(maxLines: 100)..resize(80, 24);
      terminal.write('$probe.');
      final line = terminal.buffer.lines[0];
      expect(
        line.getAttributes(0),
        0,
        reason: 'no attribute may survive $probe',
      );
    }
  });

  test('an ordinary SGR still applies', () {
    final terminal = Terminal(maxLines: 100)..resize(80, 24);
    terminal.write('\x1b[4;2m.');
    expect(terminal.buffer.lines[0].getAttributes(0), isNot(0));
  });
}
