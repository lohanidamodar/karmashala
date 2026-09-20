import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/terminal/data/process_shutdown.dart';

/// Closing a pane must not wait on a process that will not go.
///
/// The 2026-09-10 hang: a pane closed in a running 1.20.1 blocked the app's
/// main thread inside `flutter_pty.dll!pty_destroy`, which ends in
/// `ClosePseudoConsole` — a call that does not return until the console host
/// behind the pane has gone, and the host does not go while its child tree
/// lives. A WSL pane whose Linux side keeps running is the ordinary case, and
/// four such hosts were alive in the minidump. Nothing in Dart could bound it,
/// because a synchronous native call that never returns takes the isolate with
/// it.
///
/// The plugin half of the fix is native and lives behind a source guard
/// (`test/tooling/pty_destroy_contract_test.dart`) and a harness
/// (`test/tooling/pty_destroy_timing_test.dart`). This is the Dart half: the
/// pane-close sequence, driven with a child that refuses to die.
///
/// `PtyTerminalInstance` holds a real [Pty] and cannot be built in a test,
/// which is exactly why [closePaneProcess] is a named function rather than an
/// inline `whenComplete`.
void main() {
  // Small, so a test that waits out the bound is quick. What is under test is
  // that the wait ends at all and what happens on the far side of it, never how
  // many milliseconds the machine took to notice — see the ceiling below.
  const bound = Duration(milliseconds: 50);

  /// A child that ignores everything, and a `taskkill` that never comes back:
  /// the shape of the pane in the dump.
  ({Future<PaneCloseReport> close, List<String> events}) closeAnImmortalPane({
    bool keepConsole = false,
  }) {
    final events = <String>[];
    return (
      events: events,
      close: closePaneProcess(
        kill: (signal) {
          events.add('kill:${signal.toString().split('.').last}');
          return true;
        },
        // Never exits. This is the WSL session still running on the Linux side.
        exitCode: Completer<int>().future,
        pid: 4242,
        supportsGracefulSignal: false,
        // Never returns. Bitdefender's user-mode hooks sat on the same stack in
        // the dump; a `taskkill` that hangs is a real shape, not a hypothetical.
        killTree: (pid) => Completer<void>().future,
        treeKillBound: bound,
        keepPseudoConsole: () => keepConsole,
        releasePseudoConsole: () => events.add('release'),
      ),
    );
  }

  test('the close returns even though neither the child nor the kill ever '
      'does', () async {
    final stopwatch = Stopwatch()..start();
    final pane = closeAnImmortalPane();

    // Before any await: the sequence must not have done the synchronous part of
    // its work eagerly, and must not have released anything yet.
    expect(pane.events, isEmpty);

    final report = await pane.close;
    stopwatch.stop();

    // A ceiling, not a measurement. Every bound here is a real timeout, so a
    // loaded machine overshoots it and the number becomes a reading of the
    // machine — the reason `live-timing` exists. Twenty times the bound is
    // scheduler noise; not returning at all is the bug.
    expect(
      stopwatch.elapsed,
      lessThan(const Duration(seconds: 1)),
      reason: 'closing a pane must not wait on a process that will not go',
    );
    expect(report.outcome, ProcessShutdownOutcome.notObserved);
  });

  test(
    'and releases the console on the far side of the bound, not before it',
    () async {
      final pane = closeAnImmortalPane();
      final report = await pane.close;

      // The kill is what is tried first and the release is what happens after the
      // wait for it is abandoned. The order is the whole sequence: kill the tree
      // with the quit's bound, then let go.
      expect(pane.events, ['kill:SIGTERM', 'release']);
      expect(report.consoleReleased, isTrue);
    },
  );

  test('the log line says the tree was not seen gone', () async {
    final report = await closeAnImmortalPane().close;

    // §19's rule at the line: the console was released next to a tree nobody
    // watched leave, and the log must not round that up to "reaped". A dump was
    // the only way to answer this question on 2026-09-10.
    expect(
      report.summary,
      'console released, tree not seen gone within the bound',
    );
  });

  test('a quit that arrives mid-reap still keeps the console', () async {
    // `keepPseudoConsoleOnDispose` is set by the shutdown, and a pane closed a
    // moment earlier can still be reaping when it lands: `dispose` returns
    // early the second time, but the flag is set before that early return. So
    // the flag is read *after* the reap, and a release must not slip through.
    final events = <String>[];
    var quitting = false;

    final close = closePaneProcess(
      kill: (_) => true,
      exitCode: Completer<int>().future,
      pid: 7,
      supportsGracefulSignal: false,
      killTree: (_) => Completer<void>().future,
      treeKillBound: bound,
      keepPseudoConsole: () => quitting,
      releasePseudoConsole: () => events.add('release'),
    );

    // The quit lands while the bound is still running.
    quitting = true;
    final report = await close;

    expect(
      events,
      isEmpty,
      reason: 'the OS reclaims it; the quit must not wait',
    );
    expect(report.consoleReleased, isFalse);
    expect(report.summary, contains('console left to the OS (quit)'));
  });

  test('a pane whose child does go says so, and still releases', () async {
    final exit = Completer<int>();
    final events = <String>[];

    final close = closePaneProcess(
      kill: (_) => true,
      exitCode: exit.future,
      pid: 9,
      supportsGracefulSignal: false,
      // Still running, as `taskkill.exe` is for most of its life: the pane's own
      // exit is the tree kill having worked, and arrives well before the binary
      // finishes walking the process table.
      killTree: (_) => Completer<void>().future,
      treeKillBound: const Duration(days: 1),
      keepPseudoConsole: () => false,
      releasePseudoConsole: () => events.add('release'),
    );

    exit.complete(0);
    final report = await close;

    expect(report.outcome, ProcessShutdownOutcome.exited);
    expect(report.summary, 'console released, tree gone');
    expect(events, ['release']);
  });

  test('a pane already known to have exited kills no tree', () async {
    var treeKills = 0;
    final report = await closePaneProcess(
      kill: (_) => true,
      exitCode: Future.value(0),
      // Null once the process is known to have gone: the OS recycles pids, and
      // a stale number could name a stranger.
      pid: null,
      supportsGracefulSignal: false,
      killTree: (_) async => treeKills++,
      keepPseudoConsole: () => false,
      releasePseudoConsole: () {},
    );

    expect(treeKills, 0);
    expect(report.outcome, ProcessShutdownOutcome.alreadyGone);
    expect(report.summary, 'console released, tree already gone');
  });

  test(
    'a kill returning first is not the same evidence as the child going',
    () async {
      final report = await closePaneProcess(
        kill: (_) => true,
        exitCode: Completer<int>().future,
        pid: 11,
        supportsGracefulSignal: false,
        killTree: (_) async {},
        treeKillBound: const Duration(days: 1),
        keepPseudoConsole: () => false,
        releasePseudoConsole: () {},
      );

      // `taskkill` came back, which usually means the tree is gone — and usually
      // is not observed. The log says which.
      expect(report.outcome, ProcessShutdownOutcome.killReturned);
      expect(report.outcome.processGone, isFalse);
      expect(
        report.summary,
        'console released, kill returned, tree not seen gone',
      );
    },
  );

  test('a release that throws does not fail the close', () async {
    // Tearing down a pane must never throw, and after the plugin fix the
    // release is a request rather than a completion — there is nothing left for
    // it to fail at, but the guarantee is the pane's, not the plugin's.
    await expectLater(
      closePaneProcess(
        kill: (_) => true,
        exitCode: Future<int>.error(StateError('gone')),
        pid: null,
        supportsGracefulSignal: false,
        keepPseudoConsole: () => false,
        releasePseudoConsole: () {},
      ),
      completes,
    );
  });

  test('the bound a pane close uses is the quit step it borrows', () {
    // A pane close and a quit reap the same way on purpose. If they drift, the
    // pane close is the one nobody is watching.
    expect(kProcessTreeKillBound, const Duration(milliseconds: 2500));
  });

  test('the POSIX path releases the console too', () async {
    // Nothing on Linux or macOS blocks here — `pty_destroy` is a `close()` —
    // but the pane must still give the descriptor back, which is the whole
    // reason a running app releases it at all.
    final events = <String>[];
    final report = await closePaneProcess(
      kill: (signal) {
        events.add(signal.toString().split('.').last);
        return true;
      },
      exitCode: Future.value(0),
      supportsGracefulSignal: true,
      gracePeriod: bound,
      keepPseudoConsole: () => false,
      releasePseudoConsole: () => events.add('release'),
    );

    expect(events, ['SIGHUP', 'release']);
    expect(report.consoleReleased, isTrue);
    expect(report.outcome, ProcessShutdownOutcome.exited);
  });
}
