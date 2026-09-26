/// The bytes a pane sends when the wheel turns, pinned against the package's
/// own handler.
///
/// These assertions used to run against `KarmashalaMouseHandler`, which existed
/// because stock xterm 4.0.0 reported the wheel as buttons 68/69 instead of
/// 64/65 and so stopped tmux scrolling. xterm2's `TerminalMouseButton` carries
/// the spec ids, so that handler corrected nothing — and it *lost* two things
/// the package does correctly, which is why it is gone rather than kept as an
/// identity:
///
/// * `TerminalMouseEvent.modifiers`, which xterm2's scroll handler fills in,
///   was dropped — so `Ctrl+wheel` reported a plain 64 instead of 80.
/// * a coordinate past the X10 limit was reported as a NUL byte rather than
///   suppressed, putting `\x00` into the program's input.
///
/// The wire format is still worth pinning: it is what makes tmux, vim, less and
/// htop scroll, and a package bump could move it without any of our code
/// changing. So the tests moved here and the handler did not come with them.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:xterm2/xterm.dart';

/// tmux's `set -g mouse on` turns on VT200 tracking plus SGR encoding.
const _vt200Mouse = '\x1b[?1000h';
const _sgrEncoding = '\x1b[?1006h';

Terminal _terminalWith(String modes) {
  final terminal = Terminal(maxLines: 100)..resize(80, 24);
  terminal.write(modes);
  return terminal;
}

String? _report(
  Terminal terminal,
  TerminalMouseButton button, {
  TerminalMouseButtonState state = TerminalMouseButtonState.down,
  CellOffset position = const CellOffset(9, 18),
  TerminalMouseModifiers modifiers = TerminalMouseModifiers.none,
}) {
  return defaultMouseHandler(
    TerminalMouseEvent(
      button: button,
      buttonState: state,
      position: position,
      state: terminal,
      platform: TerminalTargetPlatform.windows,
      modifiers: modifiers,
    ),
  );
}

void main() {
  group('SGR encoding — what tmux, vim and htop actually negotiate', () {
    test('wheel up reports button 64, the xterm-spec code', () {
      // Verified against real tmux 3.7b: button 64 scrolls (enters copy-mode),
      // button 68 — what xterm 4.0.0 emitted — does nothing, because tmux reads
      // bit 2 of 68 as the Shift modifier and no default binding matches
      // Shift+WheelUpPane.
      final terminal = _terminalWith('$_vt200Mouse$_sgrEncoding');
      expect(_report(terminal, TerminalMouseButton.wheelUp), '\x1b[<64;10;19M');
    });

    test('wheel down reports button 65', () {
      final terminal = _terminalWith('$_vt200Mouse$_sgrEncoding');
      expect(
        _report(terminal, TerminalMouseButton.wheelDown),
        '\x1b[<65;10;19M',
      );
    });

    test('horizontal wheel reports 66 and 67', () {
      final terminal = _terminalWith('$_vt200Mouse$_sgrEncoding');
      expect(
        _report(terminal, TerminalMouseButton.wheelLeft),
        startsWith('\x1b[<66;'),
      );
      expect(
        _report(terminal, TerminalMouseButton.wheelRight),
        startsWith('\x1b[<67;'),
      );
    });

    test('no modifier bit is ever set on a plain wheel event', () {
      // The whole of the original bug: 68 = 64 + 4, and bit 2 means Shift.
      final terminal = _terminalWith('$_vt200Mouse$_sgrEncoding');
      for (final button in [
        TerminalMouseButton.wheelUp,
        TerminalMouseButton.wheelDown,
      ]) {
        final code = int.parse(
          _report(terminal, button)!.split('<')[1].split(';')[0],
        );
        expect(code & 4, 0, reason: 'shift bit must be clear');
        expect(code & 8, 0, reason: 'meta bit must be clear');
        expect(code & 16, 0, reason: 'ctrl bit must be clear');
        expect(code & 64, 64, reason: 'wheel bit must be set');
      }
    });

    test('a held modifier rides the report, in xterm\'s own bits', () {
      // What the deleted handler dropped. `TerminalView`'s scroll handler fills
      // `modifiers` in from the real keyboard, so a program that binds
      // `Ctrl+wheel` — a zoom, in most of them — sees the modifier only if it
      // survives to the wire.
      final terminal = _terminalWith('$_vt200Mouse$_sgrEncoding');
      String? withModifier(TerminalMouseModifiers modifiers) =>
          _report(terminal, TerminalMouseButton.wheelUp, modifiers: modifiers);
      expect(
        withModifier(const TerminalMouseModifiers(shift: true)),
        '\x1b[<68;10;19M',
        reason: '64 + 4',
      );
      expect(
        withModifier(const TerminalMouseModifiers(alt: true)),
        '\x1b[<72;10;19M',
        reason: '64 + 8',
      );
      expect(
        withModifier(const TerminalMouseModifiers(control: true)),
        '\x1b[<80;10;19M',
        reason: '64 + 16',
      );
    });
  });

  group('normal (X10) encoding', () {
    test('wheel up is 32 + 64, with 1-based unmodified coordinates', () {
      final terminal = _terminalWith(_vt200Mouse);
      final report = _report(terminal, TerminalMouseButton.wheelUp)!;
      expect(report.substring(0, 3), '\x1b[M');
      expect(report.codeUnitAt(3), 32 + 64);
      expect(report.codeUnitAt(4), 32 + 10);
      expect(report.codeUnitAt(5), 32 + 19);
    });

    test('a coordinate past the encoding\'s limit reports nothing', () {
      // X10 spends one printable byte per axis, so column 224 has no encoding.
      // The deleted handler wrote a NUL byte in its place, which is a byte the
      // program reads as input. Not reporting is the only honest answer.
      final terminal = _terminalWith(_vt200Mouse)..resize(400, 400);
      expect(
        _report(
          terminal,
          TerminalMouseButton.wheelUp,
          position: const CellOffset(300, 300),
        ),
        isNull,
      );
    });
  });

  group('when the application is not tracking the mouse', () {
    test('no report is produced, so the view can simulate arrow keys', () {
      // This is what makes `less`, `man` and a default tmux scroll at all.
      final terminal = _terminalWith('');
      expect(_report(terminal, TerminalMouseButton.wheelUp), isNull);
    });

    test('click-only tracking does not report the wheel', () {
      final terminal = _terminalWith('\x1b[?9h');
      expect(_report(terminal, TerminalMouseButton.wheelUp), isNull);
    });
  });

  test('a wheel release is never reported', () {
    final terminal = _terminalWith('$_vt200Mouse$_sgrEncoding');
    expect(
      _report(
        terminal,
        TerminalMouseButton.wheelUp,
        state: TerminalMouseButtonState.up,
      ),
      isNull,
    );
  });

  group('non-wheel buttons', () {
    test('report their own ids, unchanged by any of this', () {
      final terminal = _terminalWith('$_vt200Mouse$_sgrEncoding');
      expect(_report(terminal, TerminalMouseButton.left), '\x1b[<0;10;19M');
      expect(_report(terminal, TerminalMouseButton.right), '\x1b[<2;10;19M');
    });
  });
}
