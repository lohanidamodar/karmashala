import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The Windows spawn's `Sleep(1000)` must stay until something better replaces
/// it, and the reason must stay with it.
///
/// This test used to assert the opposite. `Pty.start` calls `pty_create`
/// through a **synchronous** FFI binding from `PtyTerminalInstance`'s
/// constructor, so upstream 0.4.2's unconditional second was spent on the UI
/// isolate inside a button handler — two orders of magnitude more than
/// everything else the start path does put together. Removing it looked
/// obviously right, and shipped in 1.10.0.
///
/// **It froze the app hard enough to need Task Manager.** The second is not
/// protecting the spawn — that reasoning was sound, and is why removing it
/// looked safe. It is protecting every *subsequent* ConPTY call from reaching a
/// conhost that has not finished coming up. `terminal.onResize` calls
/// `pty_resize` → `ResizePseudoConsole` synchronously **on the UI isolate**,
/// and the first one fires as soon as a new pane lays out; against an
/// uninitialised conhost it does not return, and the isolate never produces
/// another frame. The owner was resizing the window when it went.
///
/// So this now guards the sleep rather than banning it. Removing it again is a
/// real option — the honest fix is to stop making blocking ConPTY calls from
/// the UI isolate, or to gate the first resize on evidence the child is up —
/// but it needs `powershell tool/live_tests.ps1 -Family wsl` against a real
/// ConPTY first, and `live_pane_resize_test.dart` is the case that matters.
///
/// A **source** assertion, like `pty_fd_lifecycle_test.dart`'s: the plugin's
/// library exists only inside a built app, so `flutter test` cannot call it.
void main() {
  const windows = '../packages/flutter_pty/src/flutter_pty_win.c';

  test('the Windows spawn still waits for conhost', () {
    final code = File(windows).readAsStringSync();
    expect(
      RegExp(r'^\s*Sleep\s*\(\s*1000\s*\)\s*;', multiLine: true).hasMatch(code),
      isTrue,
      reason:
          'Removing this froze the app in ResizePseudoConsole on the UI '
          'isolate. Verify with live_pane_resize_test.dart before trying '
          'again — see this file\'s comment.',
    );
  });

  test('and says why, so the next removal is a decision and not a tidy-up', () {
    final code = File(windows).readAsStringSync();
    expect(code, contains('DIVERGENCE (Karmashala)'));
    expect(
      code,
      contains('ResizePseudoConsole'),
      reason:
          'the comment must name the call that blocks, or a re-vendor drops '
          'the only record of what the sleep is for',
    );
  });

  test('the POSIX half still sleeps nowhere', () {
    // The same `pty_create` contract, and it has never needed one — which is
    // what says the Windows sleep is about conhost and not about spawning.
    for (final source in const [
      '../packages/flutter_pty/src/flutter_pty_unix.c',
      '../packages/flutter_pty/src/forkpty.c',
    ]) {
      final lines = File(source).readAsLinesSync();
      final sleeps = [
        for (var i = 0; i < lines.length; i++)
          if (_sleeps(lines[i])) '$source:${i + 1}: ${lines[i].trim()}',
      ];
      expect(sleeps, isEmpty, reason: sleeps.join('\n'));
    }
  });
}

/// Whether [line] is a call to a blocking sleep, ignoring comments.
bool _sleeps(String line) {
  final code = line.trim();
  if (code.startsWith('//') || code.startsWith('*')) return false;
  return RegExp(r'\b(Sleep|sleep|usleep|nanosleep)\s*\(').hasMatch(code);
}
