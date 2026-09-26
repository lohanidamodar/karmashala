import 'dart:async';
import 'dart:io';

import 'package:agent_cli/descriptors.dart' show AgentActivityStatus;
import 'package:agent_cli/process.dart';
import 'package:karmashala_agent_status/karmashala_agent_status.dart'
    show HostedAgentStatus;
import 'package:karmashala_automations/check_runner.dart';
import 'package:karmashala_automations/persistence.dart';
import 'package:karmashala_automations/runner.dart';
import 'package:karmashala_automations/runs.dart';
import 'package:karmashala_automations/scheduler.dart';
import 'package:karmashala_checkpoints/checkpoints.dart';
import 'package:karmashala_core/util.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala_verification/command_checks.dart';
import 'package:karmashala_verification/store.dart';
import 'package:path/path.dart' as p;

import '../domain/session_registry.dart';
import '../domain/uuid.dart';
import '../protocol/messages.dart';
import 'automation_app_relay.dart';
import 'automation_handler.dart';
import 'daemon_automation_firing.dart';
import 'daemon_base_checkpoint.dart';
import 'daemon_checkout_facts.dart';
import 'daemon_resume_firing.dart';
import 'daemon_run_checks.dart';
import 'first_run_prompt_watch.dart';
import 'hosted_agent_launcher.dart';
import 'hosted_check_runner.dart';
import 'session_mcp_access.dart';

/// Automations and checks in the daemon: the one scheduler, the runs it
/// starts in sessions it owns, their verdicts when those sessions end, and
/// the checks after — with the app told of every write, and asked only for
/// what it alone can do.
class DaemonAutomations implements AutomationHandler {
  DaemonAutomations({
    required AppDatabase database,
    required SessionRegistry registry,
    required String dataDirectory,
    required SessionMcpAccessPoint mcp,
    required void Function() announce,
    DateTime Function()? clock,
    String Function()? newId,
    AutomationTimer? timer,
    bool? windows,
    RunBaseCheckpoint? checkpoints,
    Map<String, String>? hostEnvironment,
    Duration firstRunPromptInterval = const Duration(seconds: 2),
    Duration firstRunPromptWithin = const Duration(minutes: 3),
    void Function(String message)? log,
  }) : _db = database,
       _announce = announce,
       _log = log ?? _ignore {
    final now = clock ?? _utcNow;
    final ids = newId ?? newUuid;
    final automations = AutomationDao(database);
    final resumes = ScheduledResumeDao(database);
    final projectChecks = ProjectCheckDao(database);
    final sessions = SessionDao(database);
    final rows = CheckoutRows(database);
    facts = DaemonCheckoutFacts(rows, windows: windows);
    _sessions = sessions;
    _automations = automations;

    final checkRunner = ProjectCheckRunner(
      automations: automations,
      checks: projectChecks,
      facts: facts,
      commands: HostedCheckRunner(
        registry: registry,
        newId: ids,
        stopping: () => _stopped,
      ),
      recorder: CommandCheckRecorder(
        VerificationDao(database),
        VerificationArtifactStore(
          Directory(p.join(dataDirectory, 'verification')),
        ),
        newId: () => verificationRunId(now()),
        now: now,
        onChanged: _changed,
      ),
      now: now,
      onChanged: _changed,
      log: _log,
    );
    checks = checkRunner;
    final preflight = UnattendedPreflight(facts: facts, checks: projectChecks);
    final runner = AutomationRunner(
      automations: automations,
      preflight: preflight,
      facts: facts,
      checkpoints:
          checkpoints ??
          DaemonBaseCheckpoint(
            CheckpointService(
              runnerFactory: const CommandRunnerFactory(),
              environmentOf: rows.environment,
              dao: CheckpointDao(database),
              clock: _FunctionClock(now),
              newId: ids,
            ),
          ),
      launcher: HostedAgentLauncher(
        registry: registry,
        sessions: sessions,
        mcp: mcp,
        now: now,
        newId: ids,
        hostEnvironment: hostEnvironment,
        onLaunched: (sessionId, agentId, directory) => firstRunPrompts.follow(
          sessionId: sessionId,
          agentId: agentId,
          directory: directory,
        ),
      ),
      now: now,
      newId: ids,
      onChanged: _changed,
    );
    final resumeFiring = DaemonResumeFiring(
      relay: relay,
      resumes: resumes,
      now: now,
      onChanged: (_) => _changed(),
    );
    scheduler = AutomationScheduler(
      automations: automations,
      resumes: resumes,
      sessionOf: sessions.getById,
      firing: DaemonAutomationFiring(
        local: runner,
        facts: facts,
        relay: relay,
        automations: automations,
        now: now,
        newId: ids,
      ),
      resumeFiring: resumeFiring,
      timer: timer ?? WallClockAutomationTimer(),
      now: now,
      newId: ids,
      onChanged: _changed,
      onResumeChanged: (_) => _changed(),
    );
    resumeFiring.scheduler = scheduler;
    final runChecks = DaemonRunChecks(
      checks: checkRunner,
      facts: facts,
      relay: relay,
      automations: automations,
    );
    settler = AutomationRunSettler(
      automations: automations,
      sessionOf: sessions.getById,
      runChecks: runChecks.start,
      drain: scheduler.drain,
      now: now,
      onChanged: _changed,
      log: _log,
    );
    firstRunPrompts = FirstRunPromptWatch(
      registry: registry,
      interval: firstRunPromptInterval,
      within: firstRunPromptWithin,
      onBlocked: (sessionId, reason) {
        final run = automations.runForSession(sessionId);
        if (run == null) return false;
        if (run.state == AutomationRunState.running) {
          _log('automations: run ${run.id} is blocked: $reason');
          settler.finish(run, AutomationRunState.failed, reason);
        }
        return true;
      },
    );
    relay.onConnected = () => unawaited(_reconcile());
  }

  final AppDatabase _db;
  final void Function() _announce;
  final void Function(String message) _log;
  late final SessionDao _sessions;
  late final AutomationDao _automations;

  final AutomationAppRelay relay = AutomationAppRelay();
  late final DaemonCheckoutFacts facts;
  late final AutomationScheduler scheduler;
  late final AutomationRunSettler settler;
  late final ProjectCheckRunner checks;

  /// Each agent this host starts is watched, briefly, for a first-run
  /// question nobody is there to answer; its run then fails with the reason.
  late final FirstRunPromptWatch firstRunPrompts;

  StreamSubscription<SessionLifecycleChange>? _statusChanges;
  StreamSubscription<HostedAgentStatus>? _agentStatuses;

  /// What the agent of each running run this host launched is doing, by run
  /// id — the host's own status, so a run can be seen waiting on a person (or
  /// idle) before its process ends. Settling still waits for the process.
  final Map<String, HostedAgentStatus> runAgentStatus = {};
  var _stopped = false;
  var _announcing = false;

  static void _ignore(String _) {}
  static DateTime _utcNow() => DateTime.now().toUtc();

  /// Arms the scheduler — firing once what fell due while no host ran, inside
  /// the grace — settles runs whose sessions ended meanwhile, and follows
  /// every status the host writes from now on.
  Future<void> start(
    Stream<SessionLifecycleChange> statusChanges, {
    Stream<HostedAgentStatus>? agentStatus,
  }) async {
    _statusChanges = statusChanges.listen(_onStatus);
    _agentStatuses = agentStatus?.listen(_onAgentStatus);
    settler.sweep(owns: _ownsSession);
    await scheduler.start();
  }

  Future<void> close() async {
    _stopped = true;
    firstRunPrompts.close();
    scheduler.stop();
    relay.close();
    await _statusChanges?.cancel();
    await _agentStatuses?.cancel();
  }

  /// A hosted agent's status moved. For a run's agent it is kept by run, and a
  /// wait on a person is said once in the log — nobody may be watching.
  void _onAgentStatus(HostedAgentStatus status) {
    final run = _automations.runForSession(status.sessionId);
    if (run == null || run.state != AutomationRunState.running) {
      runAgentStatus.removeWhere((_, s) => s.sessionId == status.sessionId);
      return;
    }
    final before = runAgentStatus[run.id]?.report.status;
    runAgentStatus[run.id] = status;
    final now = status.report.status;
    if (now == AgentActivityStatus.awaitingApproval && before != now) {
      final said = status.report.evidence.isEmpty
          ? ''
          : ': ${status.report.evidence.first.trim()}';
      _log('automations: run ${run.id} is waiting on a person$said');
    }
  }

  /// A row this host's recorder wrote. Deferred: the recorder's stream is
  /// synchronous, inside its own write.
  void _onStatus(SessionLifecycleChange change) {
    final ending = endingOfStatus(change.to);
    if (ending == null) return;
    scheduleMicrotask(() {
      if (!_stopped) settler.settleSession(change.sessionId, ending);
    });
  }

  bool _ownsSession(Session session) => sessionRunsOnThisMachine(_db, session);

  Future<void> _reconcile() async {
    if (_stopped) return;
    await scheduler.reconcile();
    scheduler.arm();
  }

  /// Many writes in one turn are one frame to the app, and one re-arm: a run
  /// that finished moves an interval's next occurrence.
  void _changed() {
    if (_announcing || _stopped) return;
    _announcing = true;
    scheduleMicrotask(() {
      _announcing = false;
      if (_stopped) return;
      scheduler.arm();
      _announce();
    });
  }

  @override
  void notice(
    Object owner,
    AutomationNoticeMessage notice,
    void Function(HostMessage) send,
  ) {
    switch (notice.kind) {
      case AutomationNoticeKind.ready:
        relay.adopt(owner, send);
      case AutomationNoticeKind.changed:
        unawaited(_reconcile());
    }
  }

  @override
  void answer(Object owner, AutomationResultMessage result) =>
      relay.answer(owner, result);

  @override
  void detach(Object owner) => relay.detach(owner);

  @override
  Future<ChecksRanMessage> runChecks(ChecksRunMessage request) async {
    ChecksRanMessage answer(
      ChecksRunOutcome outcome, {
      String? runId,
      String? message,
    }) => ChecksRanMessage(
      requestId: request.requestId,
      outcome: outcome,
      verificationRunId: runId,
      message: message,
    );
    try {
      final session = _sessions.getById(request.sessionId);
      if (session == null) {
        return answer(
          ChecksRunOutcome.failed,
          message: 'No session ${request.sessionId}.',
        );
      }
      final directory = _directoryOf(session);
      if (!facts.isHostLocal(directory)) {
        return answer(ChecksRunOutcome.elsewhere);
      }
      final result = await checks.runForSession(session, directory);
      return result == null
          ? answer(ChecksRunOutcome.none)
          : answer(ChecksRunOutcome.ran, runId: result.run.id);
    } on Object catch (error) {
      return answer(ChecksRunOutcome.failed, message: '$error');
    }
  }

  /// Where [session]'s agent works: its worktree, its recorded directory, or
  /// its checkout.
  EnvironmentPath? _directoryOf(Session session) =>
      session.worktree ??
      session.workingDirectory ??
      facts.repository(session.repositoryId)?.path;

  /// `checks_run`, answered here for a checkout on this machine; null hands
  /// the call on to the app, as every other tool.
  Future<Object?>? localTool(
    String tool,
    Map<String, dynamic> arguments,
    String? callerSessionId,
  ) {
    if (tool != 'checks_run') return null;
    final sessionId = (arguments['sessionId'] as String?) ?? callerSessionId;
    if (sessionId == null) return null;
    final session = _sessions.getById(sessionId);
    if (session == null) return null;
    final directory = _directoryOf(session);
    if (!facts.isHostLocal(directory)) return null;
    return checks
        .runForSession(session, directory)
        .then<Object?>(sessionChecksReport);
  }
}

class _FunctionClock implements Clock {
  const _FunctionClock(this._now);
  final DateTime Function() _now;
  @override
  DateTime nowUtc() => _now().toUtc();
}
