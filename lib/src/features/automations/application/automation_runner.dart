import 'dart:async';

import 'package:riverpod/riverpod.dart';

import '../../../core/util/clock_provider.dart';
import '../../../core/util/id_generator_provider.dart';
import '../../agents/application/agent_providers.dart';
import '../../checkpoints/application/checkpoint_providers.dart';
import '../../checkpoints/domain/checkpoint.dart';
import '../../follow_ups/domain/session_ending.dart';
import '../../repositories/application/repository_providers.dart';
import '../../sessions/application/session_launcher.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_signals.dart';
import '../../sessions/application/session_status_providers.dart';
import '../../sessions/domain/session_launch.dart';
import '../../sessions/domain/session_status.dart';
import '../../terminal/application/pane_exit_signal.dart';
import '../domain/automation.dart';
import '../domain/automation_run.dart';
import 'automation_check_runner.dart';
import 'automation_providers.dart';
import 'automation_scheduler.dart';
import 'unattended_preflight.dart';

/// Firing an automation: the gate again, a checkpoint of the base, a session.
///
/// **The gate runs twice, and the second time is the one that matters.**
/// Arming-time preconditions lapse — a check is deleted, an agent uninstalled,
/// an SSH host stops answering — and the fire is when the agent would actually
/// start. A refusal here is a recorded `failed` run carrying the refusal's own
/// words, never a silent skip: the scheduler's floor is the newest occurrence
/// it has a row for, so a fire that recorded nothing would come round again on
/// every tick, forever.
class AutomationRunner implements AutomationFiring {
  const AutomationRunner(this._ref);

  final Ref _ref;

  @override
  Future<void> fire(
    Automation automation,
    DateTime scheduledFor, {
    String note = '',
    AutomationRun? queued,
  }) async {
    final dao = _ref.read(automationDaoProvider);
    final now = _ref.read(clockProvider).nowUtc();

    // The row exists before anything can fail, so every outcome has somewhere
    // to be written. A drained queue entry *is* this run and is updated in
    // place rather than joined by a second row for the same occurrence.
    var run = queued == null
        ? AutomationRun(
            id: _ref.read(idGeneratorProvider).newId(),
            automationId: automation.id,
            scheduledFor: scheduledFor,
            firedAt: now,
            state: AutomationRunState.running,
            reason: note,
          )
        : queued.copyWith(
            state: AutomationRunState.running,
            reason: note.isEmpty ? queued.reason : note,
          );
    if (queued == null) {
      dao.insertRun(run);
    } else {
      dao.updateRun(run);
    }

    void settle(AutomationRunState state, String reason) {
      run = run.copyWith(state: state, reason: reason, finishedAt: now);
      dao.updateRun(run);
      _ref.read(automationsRevisionProvider.notifier).bump();
    }

    final refusal = _ref.read(unattendedPreflightProvider).refusalFor(automation);
    if (refusal != null) {
      settle(AutomationRunState.failed, refusal.reason);
      return;
    }

    final repository = _ref
        .read(repositoryDaoProvider)
        .getById(automation.repositoryId);
    final installation = _ref
        .read(agentInstallationDaoProvider)
        .getById(automation.agentInstallationId);
    // The gate has already refused both of these; this is the compiler's copy
    // of that fact, not a second opinion.
    if (repository == null || installation == null) {
      settle(
        AutomationRunState.failed,
        'The checkout or the agent went away between the gate and the launch.',
      );
      return;
    }

    // The base, before the agent touches anything. `evenIfUnchanged` because
    // undo needs a point to restore to whether or not the tree happened to
    // match the last checkpoint — a run with no base is a run that cannot be
    // taken back. Keyed by the run's own id: this chain is not a session's.
    Checkpoint? base;
    try {
      base = await _ref
          .read(checkpointServiceProvider)
          .capture(
            repository.path,
            sessionId: run.id,
            reason: CheckpointReason.manual,
            label: 'before automation "${automation.name}"',
            evenIfUnchanged: true,
          );
    } on Object catch (error) {
      settle(
        AutomationRunState.failed,
        'The working tree could not be recorded before this run, so there '
        'would be nothing to undo it with: $error',
      );
      return;
    }
    run = run.copyWith(baseCheckpointId: base?.id);
    dao.updateRun(run);

    try {
      final result = await _ref
          .read(sessionLauncherProvider)
          .launch(
            SessionLaunchRequest(
              repository: repository,
              installation: installation,
              title: automation.name,
              purpose: SessionPurpose.newSession,
              firstMessage: automation.prompt,
              // The mode the person armed. Null means they chose nothing and
              // the agent's declared default stands — which the gate has
              // already read the rung of, so it is not an unchecked path.
              permissionOverride: automation.permissionMode,
            ),
          );
      run = run.copyWith(sessionId: result.session.id);
      dao.updateRun(run);
      _ref.read(automationsRevisionProvider.notifier).bump();
    } on Object catch (error) {
      settle(AutomationRunState.failed, 'The session could not be started: $error');
    }
  }
}

final automationRunnerProvider = Provider<AutomationRunner>(
  AutomationRunner.new,
);

/// Turns "the automation's session ended" into the run's own verdict.
///
/// **It hangs on the signals the app already has** rather than inventing one:
/// the session row's own status, which is durable and survives a restart, and
/// `paneExitProvider`, which is the only one that ever says a pane-hosted agent
/// simply *finished* — `SessionEndingObserver` reads exactly this pair and this
/// deliberately copies it rather than adding a second seam.
///
/// **Watched, not read.** Riverpod 3 pauses a provider's own subscriptions
/// while nothing listens to it, so an observer nobody watches would hear no
/// session end at all — silently, which is the worst failure for a thing whose
/// whole job is noticing. `AppShell` watches it.
class AutomationRunObserver extends Notifier<int> {
  int _revision = 0;
  bool _disposed = false;

  @override
  int build() {
    _disposed = false;
    ref.onDispose(() => _disposed = true);
    // A run settling frees its checkout, and a membership or status change is
    // the only thing that can settle one.
    ref.watchSessionKinds(const {
      SessionChangeKind.membership,
      SessionChangeKind.status,
    });

    // **The clean finish**, which neither other signal carries: the row never
    // says `completed` for a pane-hosted session and the status pipeline never
    // settles on it.
    ref.listen(paneExitProvider, (_, exit) {
      if (exit == null) return;
      // Read first, because a project check's pane is not a session's and the
      // rows behind it have to be taken in the exit's own moment. This is the
      // whole of the check sequence's clock: nothing polls.
      ref.read(automationCheckRunnerProvider).noteExit(exit.paneId, exit.exitCode);
      final sessionId = exit.sessionId;
      if (sessionId == null) return;
      final ending = endingOfPaneExit(exit.exitCode);
      if (ending == null) return;
      _settle(sessionId, ending);
    });

    // **The live one**, which is the only thing that ever reports a crash for
    // a pane-hosted agent. Subscribing is not a write, so it happens here.
    final sessions = ref.read(sessionDaoProvider);
    for (final run in ref.read(automationDaoProvider).liveRuns()) {
      if (run.state != AutomationRunState.running) continue;
      final sessionId = run.sessionId;
      if (sessionId == null) continue;
      if (sessions.getById(sessionId)?.status != SessionStatus.running) continue;
      ref.listen(agentSessionStatusProvider(sessionId), (previous, next) {
        final to = next.value?.status;
        if (to == null) return;
        final transition = endingOfTransition(
          from: previous?.value?.status,
          to: to,
        );
        if (transition != null) _settle(sessionId, transition);
      });
    }

    // **The durable half**, deferred: it writes, and a provider must not
    // change another one while it is building. A row that already says how it
    // ended settles its run even if the app was not running when it happened.
    unawaited(
      Future<void>.microtask(() {
        if (!_disposed) _sweep();
      }),
    );
    return _revision;
  }

  void _sweep() {
    final dao = ref.read(automationDaoProvider);
    final sessions = ref.read(sessionDaoProvider);
    for (final run in dao.liveRuns()) {
      if (run.state != AutomationRunState.running) continue;
      final sessionId = run.sessionId;
      if (sessionId == null) continue;
      final session = sessions.getById(sessionId);
      if (session == null) {
        _finish(
          run,
          AutomationRunState.failed,
          'The session this run started is no longer in the workspace.',
        );
        continue;
      }
      final ending = endingOfStatus(session.status);
      if (ending != null) _settleWith(run, ending);
    }
  }

  void _settle(String sessionId, SessionEnding ending) {
    final run = ref.read(automationDaoProvider).runForSession(sessionId);
    if (run == null || run.state != AutomationRunState.running) return;
    _settleWith(run, ending);
  }

  void _settleWith(AutomationRun run, SessionEnding ending) {
    final state = _stateOf(ending);
    // Losing sight of a session is not an ending. The run stays `running`
    // until something is actually observed — saying "finished" here would be
    // the confident false statement §19 exists to remove, and it would free
    // the checkout for a queued run while an agent is possibly still editing.
    if (state == null) return;
    _finish(run, state, _reasonOf(ending));
  }

  /// Records the verdict, counts what the run left on the branch, runs the
  /// checkout's checks, and lets the next waiting run in this checkout start.
  void _finish(AutomationRun run, AutomationRunState state, String reason) {
    final dao = ref.read(automationDaoProvider);
    final finished = run.copyWith(
      state: state,
      reason: reason,
      finishedAt: ref.read(clockProvider).nowUtc(),
    );
    dao.updateRun(finished);
    _revision++;
    ref.read(automationsRevisionProvider.notifier).bump();

    // **The agent stopping is not evidence the work stands**, whichever way it
    // stopped — which is why a failed ending gets its checks run too. Started
    // and not awaited: a checkout's test suite takes minutes, and this is a
    // pane exit rather than a call anybody made.
    ref.read(automationCheckRunnerProvider).start(finished);

    final automation = dao.getById(run.automationId);
    if (automation == null) return;
    // A busy checkout queues; this is the other half of that sentence.
    unawaited(
      ref.read(automationSchedulerProvider.notifier).drain(
        automation.repositoryId,
      ),
    );
  }

  /// The run's verdict for one ending, or **null when the ending is not one**.
  static AutomationRunState? _stateOf(SessionEnding ending) => switch (ending) {
    SessionEnding.completed => AutomationRunState.finished,
    SessionEnding.failed => AutomationRunState.failed,
    SessionEnding.cancelled => AutomationRunState.failed,
    SessionEnding.handedOff => AutomationRunState.finished,
    SessionEnding.lostTrack => null,
    SessionEnding.unrecognised => null,
  };

  static String _reasonOf(SessionEnding ending) =>
      'The agent this run started ${ending.label}.';
}

final automationRunObserverProvider =
    NotifierProvider<AutomationRunObserver, int>(AutomationRunObserver.new);
