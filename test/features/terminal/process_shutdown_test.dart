import 'dart:async';
import 'dart:io';

import 'package:chitragupta/src/features/terminal/data/process_shutdown.dart';
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
}

/// Runs [body] against a fresh fake process.
Future<void> _withFakeProcess(
  Future<void> Function(_FakeProcess) body, {
  required bool gracefulWorks,
}) async {
  final process = _FakeProcess(gracefulWorks: gracefulWorks);
  await body(process);
}
