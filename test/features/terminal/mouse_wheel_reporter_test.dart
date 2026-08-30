import 'package:chitragupta/src/features/terminal/domain/mouse_wheel_reporter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

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
}) {
  return const ChitraguptaMouseHandler()(
    TerminalMouseEvent(
      button: button,
      buttonState: state,
      position: position,
      state: terminal,
      platform: TerminalTargetPlatform.windows,
    ),
  );
}

void main() {
  group('SGR encoding — what tmux, vim and htop actually negotiate', () {
    test('wheel up reports button 64, the xterm-spec code', () {
      // Verified against real tmux 3.7b: button 64 scrolls (enters copy-mode),
      // button 68 — what xterm 4.0.0 emits — does nothing, because tmux reads
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
      // The whole bug: 68 = 64 + 4, and bit 2 means Shift.
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
    test('are left to the package handler, unchanged', () {
      // Only the wheel ids are wrong upstream; clicks must keep working
      // exactly as they do today.
      final terminal = _terminalWith('$_vt200Mouse$_sgrEncoding');
      expect(_report(terminal, TerminalMouseButton.left), '\x1b[<0;10;19M');
      expect(_report(terminal, TerminalMouseButton.right), '\x1b[<2;10;19M');
    });
  });
}
