import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// `pty_create` must not block the isolate that asks for a pty.
///
/// `Pty.start` calls `pty_create` through a **synchronous** FFI binding, and
/// this app calls `Pty.start` from `PtyTerminalInstance`'s constructor —
/// inside `TerminalSessionsController.startPane`, inside the Start button's
/// `onPressed`. So whatever `pty_create` spends is spent on the UI isolate,
/// with no frame produced until it returns.
///
/// Upstream `flutter_pty` 0.4.2 spent **one full second** there: a bare
/// `Sleep(1000)` between `CreatePseudoConsole` and `CreateProcessW`, on every
/// Windows spawn, unconditionally. That is two orders of magnitude more than
/// everything else the start path does put together (the parse, the encode and
/// the layout save come to ~10 ms between them), and it is the whole of the
/// owner's "starting each session ... was lagging for some time". The POSIX
/// half of the same plugin sleeps nowhere.
///
/// This is a **source** assertion rather than a behavioural one, and says so.
/// The plugin's library exists only inside a built app, so `flutter test`
/// cannot load it — the same reason `pty_fd_lifecycle_test.dart` compiles the
/// C rather than calling it. What this can still do is stop a re-vendor or an
/// upstream merge quietly putting the second back.
void main() {
  test('no blocking sleep on the pty spawn path', () {
    for (final source in const [
      'packages/flutter_pty/src/flutter_pty_win.c',
      'packages/flutter_pty/src/flutter_pty_unix.c',
      'packages/flutter_pty/src/forkpty.c',
    ]) {
      final lines = File(source).readAsLinesSync();
      final sleeps = [
        for (var i = 0; i < lines.length; i++)
          if (_sleeps(lines[i])) '$source:${i + 1}: ${lines[i].trim()}',
      ];
      expect(
        sleeps,
        isEmpty,
        reason:
            'pty_create runs on the isolate that called Pty.start, which here '
            'is the UI isolate inside a button handler:\n${sleeps.join('\n')}',
      );
    }
  });
}

/// Whether [line] is a call to a blocking sleep, ignoring comments — the
/// explanation of the one that was removed names it, and must not trip this.
bool _sleeps(String line) {
  final code = line.trim();
  if (code.startsWith('//') || code.startsWith('*')) return false;
  return RegExp(r'\b(Sleep|sleep|usleep|nanosleep)\s*\(').hasMatch(code);
}
