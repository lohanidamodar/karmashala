import 'package:riverpod/riverpod.dart';

import 'package:karmashala_core/logging.dart';
import '../../terminal/application/pane_exit_signal.dart';
import '../../verification/application/verification_providers.dart';
import 'package:karmashala_flutter_apps/flutter_apps.dart';
import 'flutter_loop.dart';

/// Turns a gate in a pane into a recorded verdict when its process stops. Must
/// be watched, and a pane closed by hand never reaches it, so keeps no verdict.
class FlutterGateObserver extends Notifier<void> {
  /// Recording is serialized, so two gates finishing together cannot interleave
  /// their writes.
  Future<void> _queue = Future<void>.value();

  /// Everything a pane exit set off has been written. Nothing in the app awaits
  /// it; a test reads it back and needs to know the write landed.
  Future<void> drain() => _queue;

  @override
  void build() {
    ref.listen(paneExitProvider, (_, exit) {
      if (exit == null) return;
      // One subscription for every pane in the app, and nearly every exit
      // belongs to something else; `noteExit` answers null for those.
      final loop = ref.read(flutterLoopProvider.notifier);
      // The tail is read *before* the run is noted: the instance is still alive
      // at this moment and will not be for long.
      final tail = loop.tailOf(exit.paneId, lines: kFlutterGateRowsRecorded);
      final run = loop.noteExit(exit.paneId, exit.exitCode);
      if (run == null || !run.kind.isGate) return;
      _queue = _queue
          .then((_) => _record(run, tail, exit.sessionId))
          // A gate that could not be recorded must not stop the next one: an
          // errored future poisons every `then` chained after it.
          .catchError((Object error) {
            AppLogger.named(
              'flutter_apps',
            ).debug('recording a gate verdict failed: $error');
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
    ref
        .read(flutterLoopProvider.notifier)
        .noteRecorded(run.paneId, recorded.id);
  }
}

/// How much of a finished gate's pane is kept as its artifact — enough for
/// `flutter analyze`'s issue list or the failing end of a test run.
const int kFlutterGateRowsRecorded = 400;

final flutterGateObserverProvider = NotifierProvider<FlutterGateObserver, void>(
  FlutterGateObserver.new,
);
