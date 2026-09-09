import 'dart:async';
import 'dart:io';

import 'package:karmashala/src/features/terminal/data/process_shutdown.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeProcess {
  _FakeProcess({this.gracefulWorks = true});

  final bool gracefulWorks;
  final signals = <ProcessSignal>[];
  final _exit = Completer<int>();

  Future<int> get exitCode => _exit.future;

  bool kill(ProcessSignal signal) {
    signals.add(signal);
    // A real process exits on the graceful signal only if it honours it.
    if (gracefulWorks && signal != ProcessSignal.sigkill) _finish(0);
    if (signal == ProcessSignal.sigkill) _finish(-9);
    return true;
  }

  void _finish(int code) {
    if (!_exit.isCompleted) _exit.complete(code);
  }

  void exitOnItsOwn() => _finish(0);
}

const _fast = Duration(milliseconds: 60);

void main() {
  test('a process that exits on the polite signal is never force-killed', () {
    return _withFakeProcess((process) async {
      await shutdownProcess(
        kill: process.kill,
        exitCode: process.exitCode,
        gracePeriod: _fast,
        supportsGracefulSignal: true,
      );
      expect(process.signals, [ProcessSignal.sighup]);
      expect(
        process.signals,
        isNot(contains(ProcessSignal.sigkill)),
        reason: 'a process that cleaned up must not then be shot',
      );
    }, gracefulWorks: true);
  });

  test('a process that ignores the polite signal is force-killed after the '
      'grace period', () {
    return _withFakeProcess((process) async {
      await shutdownProcess(
        kill: process.kill,
        exitCode: process.exitCode,
        gracePeriod: _fast,
        supportsGracefulSignal: true,
      );
      expect(process.signals, [ProcessSignal.sighup, ProcessSignal.sigkill]);
    }, gracefulWorks: false);
  });

  test('a process that exits on its own during the grace period is left '
      'alone', () {
    return _withFakeProcess((process) async {
      final done = shutdownProcess(
        kill: process.kill,
        exitCode: process.exitCode,
        gracePeriod: const Duration(seconds: 5),
        supportsGracefulSignal: true,
      );
      process.exitOnItsOwn();
      await done;
      expect(process.signals, isNot(contains(ProcessSignal.sigkill)));
    }, gracefulWorks: false);
  });

  test('a platform with no graceful signal terminates once, immediately', () {
    // Windows has no gentler primitive than TerminateProcess, so pretending
    // otherwise would only add a pointless delay to every tab close.
    return _withFakeProcess((process) async {
      final started = DateTime.now();
      await shutdownProcess(
        kill: process.kill,
        exitCode: process.exitCode,
        gracePeriod: const Duration(seconds: 5),
        supportsGracefulSignal: false,
      );
      expect(process.signals, [ProcessSignal.sigterm]);
      expect(
        DateTime.now().difference(started),
        lessThan(const Duration(seconds: 1)),
        reason: 'closing a tab must not hang waiting for a grace period',
      );
    }, gracefulWorks: true);
  });

  test('a kill that throws does not escape', () {
    // The process may already be gone; tearing down a pane must never throw.
    return expectLater(
      shutdownProcess(
        kill: (_) => throw ProcessException('x', const []),
        exitCode: Completer<int>().future,
        gracePeriod: _fast,
        supportsGracefulSignal: true,
      ),
      completes,
    );
  });

  test('an exitCode future that errors does not escape', () {
    return expectLater(
      shutdownProcess(
        kill: (_) => true,
        exitCode: Future<int>.error(StateError('gone')),
        gracePeriod: _fast,
        supportsGracefulSignal: true,
      ),
      completes,
    );
  });

  group('the Windows path', () {
    test('kills the whole tree before the direct kill', () async {
      final killed = <int>[];
      final signals = <ProcessSignal>[];

      await shutdownProcess(
        kill: (signal) {
          signals.add(signal);
          return true;
        },
        exitCode: Completer<int>().future,
        pid: 4242,
        supportsGracefulSignal: false,
        killTree: (pid) async => killed.add(pid),
      );

      // Terminating a Windows process orphans its children, and the pid the PTY
      // reports is a wrapper around the shell the user types into — so the tree
      // is the only thing worth killing.
      expect(killed, [4242]);
      expect(signals, [ProcessSignal.sigterm]);
    });

    test('skips the tree when the pid may already be recycled', () async {
      var treeKills = 0;
      await shutdownProcess(
        kill: (_) => true,
        exitCode: Future.value(0),
        supportsGracefulSignal: false,
        killTree: (_) async => treeKills++,
      );
      expect(treeKills, 0);
    });

    test('a tree kill that never returns does not hold the quit open', () async {
      // The app soak's other hang shape, and the reason the wait is bounded at
      // all. `AppLifecycle._step` bounds the *step*, not the work, so a reap
      // still waiting on `taskkill` after its step was abandoned is work
      // outliving the shutdown that owns it — and `_quit` only reaches
      // `exit(0)` once every teardown it started has come back.
      //
      // Counted, not timed: what is asserted is that this completes at all and
      // that the direct kill still happened, on a tree kill that never will.
      final signals = <ProcessSignal>[];

      await shutdownProcess(
        kill: (signal) {
          signals.add(signal);
          return true;
        },
        exitCode: Completer<int>().future,
        pid: 11,
        supportsGracefulSignal: false,
        killTree: (_) => Completer<void>().future,
        treeKillBound: _fast,
      );

      expect(signals, [ProcessSignal.sigterm]);
    });

    test('the wait ends when the pane does, not when taskkill exits', () async {
      // The pane's own exit is the tree kill having worked, and it arrives
      // well before `taskkill.exe` finishes starting up, enumerating and
      // leaving: 1039-1778 ms measured for the whole call against 196-214 ms
      // for `taskkill /?`. Waiting for the binary rather than for the event put
      // most of a quit on it.
      final exit = Completer<int>();
      final signals = <ProcessSignal>[];

      final done = shutdownProcess(
        kill: (signal) {
          signals.add(signal);
          return true;
        },
        exitCode: exit.future,
        pid: 12,
        supportsGracefulSignal: false,
        // Still running, as it is for most of its life.
        killTree: (_) => Completer<void>().future,
        treeKillBound: const Duration(days: 1),
      );

      exit.complete(0);
      await done;

      expect(signals, [ProcessSignal.sigterm]);
    });

    test('the bound is the shutdown step that owns the reap', () {
      // Pinned here rather than in the lifecycle's own budget test as well,
      // because this is the file that decides it: a bound above the step's
      // slice would put the reap back outside the shutdown it belongs to.
      expect(kProcessTreeKillBound, const Duration(milliseconds: 2500));
    });

    test('a tree kill that fails does not stop the direct kill', () async {
      final signals = <ProcessSignal>[];
      await shutdownProcess(
        kill: (signal) {
          signals.add(signal);
          return true;
        },
        exitCode: Completer<int>().future,
        pid: 7,
        supportsGracefulSignal: false,
        killTree: (_) async => throw const ProcessException('taskkill', []),
      );
      expect(signals, [ProcessSignal.sigterm]);
    });
  });
}

/// Runs [body] against a fresh fake process.
Future<void> _withFakeProcess(
  Future<void> Function(_FakeProcess) body, {
  required bool gracefulWorks,
}) async {
  final process = _FakeProcess(gracefulWorks: gracefulWorks);
  await body(process);
}
