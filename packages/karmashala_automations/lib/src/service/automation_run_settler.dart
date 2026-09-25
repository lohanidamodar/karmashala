import 'dart:async';

import 'package:karmashala_session/session.dart';

import '../domain/automation.dart';
import '../domain/automation_run.dart';
import '../store/automation_dao.dart';

/// Turns "the automation's session ended" into the run's verdict, then runs
/// the checkout's checks, spends the failure budget and lets the queue move.
class AutomationRunSettler {
  AutomationRunSettler({
    required AutomationDao automations,
    required this._sessionOf,
    required this._runChecks,
    required this._drain,
    required this._now,
    void Function()? onChanged,
    void Function(String message)? log,
  }) : _dao = automations,
       _onChanged = onChanged ?? _nothing,
       _log = log ?? _ignore;

  final AutomationDao _dao;
  final Session? Function(String sessionId) _sessionOf;
  final void Function(AutomationRun finished) _runChecks;
  final Future<void> Function(String repositoryId) _drain;
  final DateTime Function() _now;
  final void Function() _onChanged;
  final void Function(String message) _log;

  static void _nothing() {}
  static void _ignore(String _) {}

  /// Settles every running run whose session row has ended; [owns] says which
  /// sessions this settler speaks for (the host: its own machine's).
  void sweep({bool Function(Session session)? owns}) {
    for (final run in _dao.liveRuns()) {
      if (run.state != AutomationRunState.running) continue;
      final sessionId = run.sessionId;
      if (sessionId == null) continue;
      final session = _sessionOf(sessionId);
      if (session == null) {
        finish(
          run,
          AutomationRunState.failed,
          'The session this run started is no longer in the workspace.',
        );
        continue;
      }
      if (owns != null && !owns(session)) continue;
      final ending = endingOfStatus(session.status);
      if (ending != null) settleWith(run, ending);
    }
  }

  /// [sessionId] ended as [ending]; the run it belongs to, if any, settles.
  void settleSession(String sessionId, SessionEnding ending) {
    final run = _dao.runForSession(sessionId);
    if (run == null || run.state != AutomationRunState.running) return;
    settleWith(run, ending);
  }

  void settleWith(AutomationRun run, SessionEnding ending) {
    final state = stateOfEnding(ending);
    // Losing sight of a session is not an ending: "finished" here would free
    // the checkout while an agent may still be editing.
    if (state == null) return;
    finish(run, state, 'The agent this run started ${ending.label}.');
  }

  /// Records the verdict, runs the checks, and lets the next run in.
  void finish(AutomationRun run, AutomationRunState state, String reason) {
    final finished = run.copyWith(
      state: state,
      reason: reason,
      finishedAt: _now(),
    );
    _dao.updateRun(finished);
    _onChanged();

    // The agent stopping is not evidence the work stands, whichever way.
    _runChecks(finished);

    // Counted before the re-read, so the disabling decision includes this run.
    _dao.recordOutcome(
      run.automationId,
      failed: state == AutomationRunState.failed,
    );
    final automation = _dao.getById(run.automationId);
    if (automation == null) return;
    _stopIfFailedOut(automation);
    unawaited(_drain(automation.repositoryId));
  }

  void _stopIfFailedOut(Automation automation) {
    if (!automation.enabled || !automation.hasFailedOut) return;
    _dao.disable(
      automation.id,
      'Stopped after ${automation.consecutiveFailures} failed runs in a row. '
      'Nothing was changed about it — look at the runs below, fix what they '
      'are failing on, and switch it back on.',
    );
    _log(
      'automations: disabled "${automation.name}" (${automation.id}) after '
      '${automation.consecutiveFailures} consecutive failures.',
    );
    _onChanged();
  }

  /// The run's verdict for one ending, or **null when it is not one**.
  static AutomationRunState? stateOfEnding(SessionEnding ending) =>
      switch (ending) {
        SessionEnding.completed => AutomationRunState.finished,
        SessionEnding.failed => AutomationRunState.failed,
        SessionEnding.cancelled => AutomationRunState.failed,
        SessionEnding.handedOff => AutomationRunState.finished,
        SessionEnding.lostTrack => null,
        SessionEnding.unrecognised => null,
      };
}
