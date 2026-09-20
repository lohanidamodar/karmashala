import 'package:karmashala_terminal_core/grid.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm2/xterm.dart';

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
    terminal.inputHandler = const KarmashalaInputHandler();
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

    test(
      'Alt+Enter is ESC CR — the meta prefix, as it always should have been',
      () {
        expect(bytesFor(TerminalKey.enter, alt: true), [0x1B, 0x0D]);
      },
    );

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
        String.fromCharCodes(bytesFor(TerminalKey.numpadEnter, ctrl: true)!),
        '\x1b[13;5u',
      );
    });
  });

  group('everything else is left to the package', () {
    test('Ctrl+C is still the interrupt byte', () {
      expect(bytesFor(TerminalKey.keyC, ctrl: true), [0x03]);
    });

    test('a plain arrow key still gets its ordinary sequence', () {
      expect(String.fromCharCodes(bytesFor(TerminalKey.arrowUp)!), '\x1b[A');
    });

    test('Tab and Backspace are untouched', () {
      expect(bytesFor(TerminalKey.tab), [0x09]);
      expect(bytesFor(TerminalKey.backspace), isNotNull);
    });
  });

  group('one keystroke is one sequence', _oneSequencePerKeystroke);

  group('through the widget that receives the key', _oneKeystrokeOnTheWire);

  group('modifier-reporting probes', _prefixedSgrIsNotSgr);
}

/// Every sequence a whole keystroke writes — the press **and** the release.
///
/// A release is not a keystroke of its own, so nothing may be written for it.
/// The vendored xterm 4.0.0 never asked: `TerminalView` returned early on a
/// `KeyUpEvent` and `TerminalKeyboardEvent` had no event type at all. xterm2
/// forwards releases so the kitty protocol can report them, and every handler
/// in its own default chain opens with a release guard. This one had none, so a
/// modified `Enter` was encoded twice per press — the reported
/// *"shift enter is creating new line twice"*.
List<String> _keystroke(
  TerminalKey key, {
  bool shift = false,
  bool ctrl = false,
  bool alt = false,
}) {
  final terminal = Terminal(maxLines: 100)..resize(80, 24);
  terminal.inputHandler = const KarmashalaInputHandler();
  final written = <String>[];
  terminal.onOutput = written.add;
  for (final type in [
    TerminalKeyEventType.press,
    TerminalKeyEventType.release,
  ]) {
    terminal.keyInput(key, shift: shift, ctrl: ctrl, alt: alt, type: type);
  }
  return written;
}

void _oneSequencePerKeystroke() {
  test('Shift+Enter writes ESC CR once, not once more on the release', () {
    expect(_keystroke(TerminalKey.enter, shift: true), [kEscapeEnter]);
  });

  test('Ctrl+Enter writes its CSI-u sequence once', () {
    expect(_keystroke(TerminalKey.enter, ctrl: true), ['\x1b[13;5u']);
  });

  test('Alt+Enter and Ctrl+Shift+Enter once each', () {
    expect(_keystroke(TerminalKey.enter, alt: true), [kEscapeEnter]);
    expect(_keystroke(TerminalKey.enter, ctrl: true, shift: true), [
      '\x1b[13;6u',
    ]);
  });

  test('the numpad Enter once too', () {
    expect(_keystroke(TerminalKey.numpadEnter, shift: true), [kEscapeEnter]);
  });

  test('plain Enter, which the package has always guarded, is one', () {
    expect(_keystroke(TerminalKey.enter), ['\r']);
  });

  test('and Ctrl+C — the shape every delegated handler already had', () {
    expect(_keystroke(TerminalKey.keyC, ctrl: true), ['\x03']);
  });
}

/// The same count, but pressed rather than called.
///
/// The cases above drive `Terminal.keyInput`. These press the key: a
/// `KeyDownEvent` and a `KeyUpEvent` through `TerminalView`'s own focus node,
/// which is the path that started delivering releases.
///
/// Run for **both** values of `hardwareKeyboardOnly`, because that flag was the
/// first suspect and is not the cause. `false` attaches the platform text-input
/// client dictation talks to, `true` swaps it for a bare key listener — and
/// both forward a `KeyUpEvent` to the same handler, so the count is identical.
/// A pane runs with `false`.
void _oneKeystrokeOnTheWire() {
  Future<List<String>> shiftEnter(
    WidgetTester tester, {
    required bool hardwareKeyboardOnly,
  }) async {
    final terminal = Terminal(maxLines: 100)
      ..inputHandler = const KarmashalaInputHandler();
    final toShell = <String>[];
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalView(
            terminal,
            focusNode: focusNode,
            hardwareKeyboardOnly: hardwareKeyboardOnly,
          ),
        ),
      ),
    );
    focusNode.requestFocus();
    await tester.pump();
    // After focus, so nothing the view does on attach is counted as a keystroke.
    terminal.onOutput = toShell.add;

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    return toShell;
  }

  testWidgets('with the text-input client attached, as a pane runs', (
    tester,
  ) async {
    expect(await shiftEnter(tester, hardwareKeyboardOnly: false), [
      kEscapeEnter,
    ]);
  });

  testWidgets('and with only the hardware keyboard, as it used to', (
    tester,
  ) async {
    expect(await shiftEnter(tester, hardwareKeyboardOnly: true), [
      kEscapeEnter,
    ]);
  });
}

/// A modifier-reporting *request* is not a colour change.
///
/// `CSI > 4 ; 2 m` (xterm's `modifyOtherKeys`) used to reach the old vendored
/// parser's SGR handler, which ignored the `>` prefix and applied SGR 4 and
/// SGR 2. Any program that asked whether it could have real modifiers left the
/// pane underlined and faint. xterm2 routes prefixed CSI sequences away from
/// SGR itself, so this is now a gate on the dependency rather than on a
/// divergence of ours.
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
