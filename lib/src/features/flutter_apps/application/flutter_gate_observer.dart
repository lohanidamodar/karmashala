import 'package:riverpod/riverpod.dart';

import 'package:karmashala_core/logging.dart';
import '../../terminal/application/pane_exit_signal.dart';
import '../../verification/application/verification_providers.dart';
import '../domain/flutter_command_run.dart';
import 'flutter_loop.dart';

/// Turns a gate running in a pane into a recorded verdict, when its process
/// stops.
///
/// **Watched, not read.** Riverpod 3 pauses a provider's own subscriptions
/// while nothing listens to it, so an observer nobody watches would hear no
/// pane stop at all — silently, which is the worst failure for something whose
/// whole job is noticing. `AppShell` watches it beside
/// `worktreeSetupExitObserverProvider`, which documents the same hazard and
/// solves the same problem for the same reason.
///
/// **A pane the user closed by hand is never recorded**, and that is
/// `PaneExitSignal`'s deliberate rule rather than an omission here: only a
/// process that stopped by itself reaches it. Such a gate keeps no verdict,
/// which is honest — nobody observed how it ended, and `flutter_run`'s status
/// says `unknown` for it rather than green.
class FlutterGateObserver extends Notifier<void> {
  /// Recording is serialized, so two gates finishing together cannot
  /// interleave their writes — the same queue idiom `VerificationRecorder`
  /// uses, and the same reason [drain] exists beside it.
  Future<void> _queue = Future<void>.value();

  /// Everything a pane exit set off has been written.
  ///
  /// Nothing in the app awaits this: an exit is not a call anybody made, so
  /// there is no caller to hold. A test reads it back and needs to know when
  /// the write landed, which is exactly what `VerificationRecorder.drain`
  /// is for on the other side of the same feature.
  Future<void> drain() => _queue;

  @override
  void build() {
    ref.listen(paneExitProvider, (_, exit) {
      if (exit == null) return;
      // One subscription for every pane in the app, and nearly every exit it
      // sees belongs to something else. `noteExit` is a list lookup that
      // answers null for those and writes nothing.
      final loop = ref.read(flutterLoopProvider.notifier);
      // The tail is read *before* the run is noted, because the instance is
      // still alive at this moment and will not be for long.
      final tail = loop.tailOf(exit.paneId, lines: kFlutterGateRowsRecorded);
      final run = loop.noteExit(exit.paneId, exit.exitCode);
      if (run == null || !run.kind.isGate) return;
      _queue = _queue
          .then((_) => _record(run, tail, exit.sessionId))
          // A gate that could not be recorded must not stop the *next* one
          // being recorded. An errored future poisons every `then` chained
          // after it, so this observer would go quiet for the rest of the
          // session over one failed disk write — the silent failure its own
          // doc says is the worst outcome here.
          .catchError((Object error) {
            AppLogger.named('flutter_apps').debug(
              'recording a gate verdict failed: $error',
            );
          });
    });
  }

  Future<void> _record(
    FlutterCommandRun run,
    List<String> tail,
    String? sessionId,
  ) async {
    final recorded = await ref
        .read(verificationServiceProvider)
        .recordCommandCheck(
          title: 'flutter ${run.kind.label} · ${run.projectDirectory}',
          command: run.command,
          workingDirectory: run.projectDirectory,
          environmentId: run.environmentId,
          startedAt: run.startedAt,
          exitCode: run.exitCode,
          output: tail.join('\n'),
          sessionId: sessionId,
          producedBySessionId: sessionId,
        );
    ref.read(flutterLoopProvider.notifier).noteRecorded(run.paneId, recorded.id);
  }
}

/// How much of a finished gate's pane is kept as its artifact.
///
/// More than a status read wants and less than a scrollback: enough to hold
/// `flutter analyze`'s issue list or the failing end of a test run, which is
/// what somebody reading the verdict later has a question about.
const int kFlutterGateRowsRecorded = 400;

final flutterGateObserverProvider =
    NotifierProvider<FlutterGateObserver, void>(FlutterGateObserver.new);
