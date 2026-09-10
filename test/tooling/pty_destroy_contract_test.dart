import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// `pty_destroy` must return immediately, and on Windows that is a contract
/// rather than an observation.
///
/// `ClosePseudoConsole` does not return until the console host behind the pty
/// has gone, and that host is a child of the *app* rather than of the shell —
/// so killing the pane's process tree does not settle it, and a child that
/// ignores the kill holds it open indefinitely. Called inline, it takes the
/// isolate with it: no Dart timeout can fire, because a `Duration` is a task
/// for the isolate that is stuck.
///
/// It cost two quits in twenty on the 2026-09-09 soak — fixed there by leaving
/// the console to the OS at quit — and then, on 2026-09-10, a whole running
/// app: a minidump of 1.20.1 caught the main thread blocked inside
/// `flutter_pty.dll!pty_destroy` under `flutter_windows.dll` with four headless
/// console hosts alive and holding live children. A pane close is the path the
/// quit fix does not cover.
///
/// A **source** assertion, like `pty_spawn_latency_test.dart`'s and
/// `pty_exit_port_test.dart`'s: the plugin's library exists only inside a built
/// app, so `flutter test` cannot call it. The runtime measurement is
/// `pty_destroy_timing_test.dart`, which needs the Windows toolchain and a real
/// console. This one runs everywhere and is what an upstream merge or a
/// re-vendor would undo.
void main() {
  const windows = 'packages/flutter_pty/src/flutter_pty_win.c';
  const header = 'packages/flutter_pty/src/flutter_pty.h';

  test('pty_destroy does not close the pseudoconsole itself', () {
    final body = _functionBody(File(windows).readAsStringSync(), 'pty_destroy');

    expect(
      body,
      isNot(contains('ClosePseudoConsole')),
      reason:
          'this is the call that never returns. Whoever calls pty_destroy may '
          'be the platform thread — see this file\'s comment.',
    );
  });

  test('it hands the close to a detached thread instead', () {
    final code = File(windows).readAsStringSync();
    final destroy = _functionBody(code, 'pty_destroy');

    expect(
      destroy,
      contains('CreateThread'),
      reason: 'the release has to happen somewhere, and not here',
    );
    // `CloseHandle` on the thread handle is Win32's `pthread_detach`, not a
    // cancel: nothing joins this worker, which is the point.
    expect(destroy, contains('CloseHandle(thread)'));

    final worker = _functionBody(code, 'close_console_thread');
    expect(worker, contains('ClosePseudoConsole'));
    expect(
      worker,
      contains('free(handle)'),
      reason: 'ownership passes to the worker; nobody else can free it',
    );
  });

  test('a thread it cannot start is left to the OS, not done inline', () {
    // The one branch where the temptation to fall back is real, and where
    // giving in would restore the hang on the machine least able to survive it.
    final destroy = _functionBody(
      File(windows).readAsStringSync(),
      'pty_destroy',
    );
    final failure = destroy.substring(destroy.indexOf('thread == NULL'));

    expect(
      failure,
      isNot(contains('ClosePseudoConsole')),
      reason: 'a machine too short of threads is the last place to block',
    );
    expect(failure, contains('return;'));
  });

  test('and the header says so, so a caller can rely on it', () {
    // The contract is the load-bearing half: `PtyTerminalInstance` releases the
    // console from a `then` on the UI isolate, and `AppLifecycle` gives the
    // terminal step a budget. Both are only safe because this returns.
    final doc = File(header).readAsStringSync();
    expect(doc, contains('Returns immediately'));
    expect(
      doc,
      contains('ClosePseudoConsole'),
      reason:
          'the header must name the call that blocks, or a re-vendor drops the '
          'only record of what the worker thread is for',
    );
  });

  test('the POSIX half still releases inline', () {
    // Its release is a `close()`, so there is nothing to defer and a thread
    // would only add a race. The divergence is Windows-only on purpose.
    final unix = File(
      'packages/flutter_pty/src/flutter_pty_unix.c',
    ).readAsStringSync();
    expect(_functionBody(unix, 'pty_destroy'), isNot(contains('CreateThread')));
  });
}

/// The body of the C function named [name] in [source], braces included.
///
/// Crude on purpose — it counts braces from the function's opening one — but
/// the alternative is asserting on the whole file, which cannot tell
/// `pty_destroy` calling `ClosePseudoConsole` from the worker doing it, and
/// that distinction is the entire subject of this file.
String _functionBody(String source, String name) {
  final signature = RegExp('[\\s*]$name\\s*\\(').firstMatch(source);
  expect(signature, isNotNull, reason: 'no function named $name');
  final open = source.indexOf('{', signature!.end);
  expect(open, greaterThan(-1), reason: '$name has no body');

  var depth = 0;
  for (var i = open; i < source.length; i++) {
    if (source[i] == '{') depth++;
    if (source[i] == '}') {
      depth--;
      if (depth == 0) return source.substring(open, i + 1);
    }
  }
  fail('$name has an unbalanced body');
}
