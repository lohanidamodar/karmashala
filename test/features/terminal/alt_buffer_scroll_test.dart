import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/terminal/domain/mouse_wheel_reporter.dart';
import 'package:xterm/xterm.dart';

/// Switch to the alternate screen buffer, which is where tmux, vim, less and
/// htop all live. It has no scrollback, so a wheel event has to become
/// something the *application* understands.
const _enterAltBuffer = '\x1b[?1049h';

/// What tmux sends for `set -g mouse on`: normal mouse tracking plus SGR
/// encoding.
const _enableMouseTracking = '\x1b[?1000h\x1b[?1006h';

/// Builds a pane the way the app does, including the externally-supplied
/// ScrollController Loop 29 added for scroll-to-match.
Future<(Terminal, List<String>)> _pumpPane(
  WidgetTester tester, {
  required String setup,
  ScrollController? scrollController,
}) async {
  // Configured exactly as PtyTerminalInstance configures a real pane.
  final terminal = Terminal(maxLines: 1000)
    ..mouseHandler = const KarmashalaMouseHandler();
  final output = <String>[];
  terminal.onOutput = output.add;

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 800,
          height: 600,
          child: TerminalView(
            terminal,
            scrollController: scrollController,
            hardwareKeyboardOnly: true,
            autofocus: true,
          ),
        ),
      ),
    ),
  );
  await tester.pump();

  terminal.write(setup);
  await tester.pump();
  output.clear();
  return (terminal, output);
}

Future<void> _wheel(WidgetTester tester, {required double dy}) async {
  final pointer = TestPointer(1, PointerDeviceKind.mouse);
  final centre = tester.getCenter(find.byType(TerminalView));
  await tester.sendEventToBinding(pointer.hover(centre));
  await tester.sendEventToBinding(pointer.scroll(Offset(0, dy)));
  await tester.pump();
}

void main() {
  testWidgets('the pane enters the alternate buffer when asked', (
    tester,
  ) async {
    final (terminal, _) = await _pumpPane(tester, setup: _enterAltBuffer);
    expect(terminal.isUsingAltBuffer, isTrue);
  });

  group('mouse tracking off — the default tmux configuration', () {
    testWidgets('a wheel scroll becomes arrow keys', (tester) async {
      // With no mouse reporting the terminal must synthesise arrow keys, which
      // is what makes `less`, `man` and a default tmux scroll at all.
      final (terminal, output) = await _pumpPane(
        tester,
        setup: _enterAltBuffer,
        scrollController: ScrollController(),
      );
      expect(terminal.isUsingAltBuffer, isTrue);

      await _wheel(tester, dy: 120);

      expect(
        output.join(),
        isNotEmpty,
        reason: 'scrolling an alt-screen app must send it something',
      );
      expect(output.join(), contains('\x1b[B'));
    });

    testWidgets('scrolling up sends up arrows', (tester) async {
      final (_, output) = await _pumpPane(
        tester,
        setup: _enterAltBuffer,
        scrollController: ScrollController(),
      );

      await _wheel(tester, dy: -120);

      expect(output.join(), contains('\x1b[A'));
    });
  });

  group('mouse tracking on — tmux with `set -g mouse on`', () {
    testWidgets('a wheel scroll becomes a mouse report', (tester) async {
      final (_, output) = await _pumpPane(
        tester,
        setup: '$_enterAltBuffer$_enableMouseTracking',
        scrollController: ScrollController(),
      );

      await _wheel(tester, dy: 120);

      // SGR wheel-down is CSI < 65 ; col ; row M. Before the fix this was
      // 69 — wheel-down with the Shift bit set — which tmux ignores.
      expect(output.join(), contains('\x1b[<65;'));
      expect(output.join(), isNot(contains('\x1b[<69;')));
    });
  });

  testWidgets('the main buffer still scrolls its own scrollback', (
    tester,
  ) async {
    // The alt-screen path must not steal the wheel from ordinary scrollback.
    final controller = ScrollController();
    final (terminal, output) = await _pumpPane(
      tester,
      setup: '',
      scrollController: controller,
    );
    for (var i = 0; i < 200; i++) {
      terminal.write('line $i\r\n');
    }
    await tester.pump();
    expect(terminal.isUsingAltBuffer, isFalse);

    await _wheel(tester, dy: -240);

    expect(
      output.join(),
      isEmpty,
      reason: 'scrollback scrolling must not be sent to the process',
    );
  });
}
