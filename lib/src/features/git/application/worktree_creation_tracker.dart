import 'dart:async';

import 'package:agent_cli/process.dart';
import 'package:karmashala_git/git.dart';

/// Raised by a worktree creation the user cancelled. [cleanup] says what was
/// removed, or what was left behind and why.
class WorktreeCreationCancelled implements Exception {
  WorktreeCreationCancelled(this.cleanup);
  final String cleanup;
  @override
  String toString() => 'Worktree creation cancelled. $cleanup';
}

/// One worktree creation in flight: its live stage record, and the lever that
/// cancels it. Cancellable only until the agent stage starts — after that the
/// worktree belongs to a session, and stopping it is ending that session.
class WorktreeCreationTracker {
  WorktreeCreationTracker({required this.repo});

  final EnvironmentPath repo;

  WorktreeCreationRecord _record = WorktreeCreationRecord.initial();
  final _changes = StreamController<WorktreeCreationRecord>.broadcast();
  final _cancel = Completer<void>();

  /// Called with every settled record after the creation itself returned — the
  /// agent stage ending, mostly — so the persisted row follows.
  void Function(WorktreeCreationRecord record)? onSettled;

  WorktreeCreationRecord get record => _record;
  Stream<WorktreeCreationRecord> get changes => _changes.stream;

  bool get isCancelled => _cancel.isCompleted;
  Future<void> get cancelled => _cancel.future;

  bool get canCancel =>
      !isCancelled &&
      !_record.outcome.isFinished &&
      _record.stage(WorktreeStage.agent).state == WorktreeStageState.pending;

  /// Asks the running stage to stop. The creation then cleans up and throws
  /// [WorktreeCreationCancelled] to whoever awaited it.
  void cancel() {
    if (canCancel) _cancel.complete();
  }

  void update(WorktreeStageStatus status) =>
      _publish(_record.withStage(status));

  void finish(WorktreeCreationOutcome outcome, {String? cleanup}) =>
      _publish(_record.finish(outcome, cleanup: cleanup));

  void replace(WorktreeCreationRecord record) => _publish(record);

  /// The session's agent was started in the worktree.
  void agentStarted() => _settleAgent(
    WorktreeStageState.done,
    'The agent was started in the worktree.',
  );

  /// The session's agent could not be started; [error] in its own words.
  void agentFailed(Object error) => _settleAgent(
    WorktreeStageState.failed,
    'The agent could not be started: $error',
  );

  void _settleAgent(WorktreeStageState state, String detail) {
    final agent = _record.stage(WorktreeStage.agent);
    if (agent.state != WorktreeStageState.running) return;
    var next = _record.withStage(agent.copyWith(state: state, detail: detail));
    // A setup script still running in its pane re-settles it when it exits.
    next = next.finish(next.settledOutcome);
    _publish(next);
    onSettled?.call(next);
  }

  void _publish(WorktreeCreationRecord record) {
    _record = record;
    if (!_changes.isClosed) _changes.add(record);
  }
}

/// The creations in flight, so a surface that did not start one — the session
/// dialog, while its launch is inside the launcher — can still draw and cancel
/// it. Plain Dart; the provider that holds it lives with the other git ones.
class WorktreeCreations {
  final List<WorktreeCreationTracker> _active = [];
  final _changes = StreamController<void>.broadcast();

  Stream<void> get changes => _changes.stream;
  List<WorktreeCreationTracker> get active => List.unmodifiable(_active);

  void add(WorktreeCreationTracker tracker) {
    _active.add(tracker);
    _changes.add(null);
  }

  void remove(WorktreeCreationTracker tracker) {
    if (_active.remove(tracker)) _changes.add(null);
  }

  /// The newest creation of a worktree of [repo], or null.
  WorktreeCreationTracker? latestFor(EnvironmentPath repo) {
    for (final tracker in _active.reversed) {
      if (tracker.repo == repo) return tracker;
    }
    return null;
  }
}
