import 'dart:async';
import 'dart:io';

import 'package:agent_cli/descriptors.dart'
    show AcpLaunchSpec, AgentActivityStatus;
import 'package:agent_cli/discovery.dart' show AgentInstallation;
import 'package:agent_cli/process.dart';
import 'package:karmashala_agent_status/karmashala_agent_status.dart'
    show HostedAgentStatus;
import 'package:karmashala_automations/automations.dart'
    show Automation, AutomationEventAction, proposalInboxId;
import 'package:karmashala_automations/webhooks.dart'
    show fillWebhookTemplate, webhookSampleBody, webhookTemplateFields;
import 'package:karmashala_automations/check_runner.dart';
import 'package:karmashala_automations/checks.dart' show carryProjectChecks;
import 'package:karmashala_automations/github.dart'
    show GithubApi, kGithubVariables;
import 'package:karmashala_automations/records.dart';
import 'package:karmashala_automations/resumes.dart'
    show ScheduledResume, ScheduledResumeState;
import 'package:karmashala_automations/store.dart';
import 'package:karmashala_automations/runner.dart';
import 'package:karmashala_automations/runs.dart';
import 'package:karmashala_automations/scheduler.dart';
import 'package:karmashala_checkpoints/checkpoints.dart';
import 'package:karmashala_checkpoints/store.dart';
import 'package:karmashala_core/util.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show
        AutomationChanged,
        CheckpointRecorded,
        ChecksRun,
        DataChange,
        DataRefused,
        SessionChecksOutcome,
        SessionChecksRun,
        SessionStatusEntry,
        UsageLimitNotice,
        VerificationRunChanged;
import 'package:karmashala_session/session.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala_verification/command_checks.dart';
import 'package:karmashala_verification/artifacts.dart';
import 'package:karmashala_verification/store.dart';
import 'package:karmashala_git/github.dart' show GithubClient;
import 'package:karmashala_git/worktrees.dart' show WorktreeService;
import 'package:path/path.dart' as p;

import '../acp/acp_auth.dart' show AcpStartAuth;
import '../acp/acp_runtimes.dart' show AcpRuntimeFactory;
import '../acp/acp_session_runtime.dart' show AcpSessionRuntime;
import '../domain/session_registry.dart';
import '../data/attention_work.dart';
import '../data/told_automations.dart';
import '../domain/uuid.dart';
import 'daemon_automation_firing.dart';
import 'daemon_base_checkpoint.dart';
import 'daemon_checkout_facts.dart';
import 'daemon_run_checks.dart';
import 'first_run_prompt_watch.dart';
import 'hosted_agent_launcher.dart';
import 'hosted_check_runner.dart';
import 'server_event_rules.dart';
import 'server_resume_runner.dart';
import 'server_usage_limits.dart';
import 'github/daemon_github.dart';
import 'step_runners.dart';
import 'session_mcp_access.dart';
import '../domain/host_session.dart';

import 'package:karmashala_notifications/attention.dart'
    show InboxItem, InboxItemKind;
import 'package:karmashala_notifications/watched.dart'
    show AgentSessionKey, WatchedSession;
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';

/// Automations and checks in the server: the one scheduler, the runs it
/// starts in sessions it owns, their verdicts when those sessions end, the
/// checks after, scheduled resumes and a client's `checks.run` — every write
/// told to every client ([tell]). No app is asked for anything (slice 5c).
class DaemonAutomations implements ChecksWork, AutomationWork {
  DaemonAutomations({
    required AppDatabase database,
    required SessionRegistry registry,
    required String dataDirectory,
    required SessionMcpAccessPoint mcp,
    required void Function(List<DataChange> changes) tell,
    CommandRunnerFactory? remote,
    void Function(String sessionId)? sessionWritten,
    DateTime Function()? clock,
    String Function()? newId,
    AutomationTimer? timer,
    bool? windows,
    RunBaseCheckpoint? checkpoints,
    Map<String, String>? hostEnvironment,
    Duration firstRunPromptInterval = const Duration(seconds: 2),
    Duration firstRunPromptWithin = const Duration(minutes: 3),
    void Function(String message)? log,
    HostedAgentStatus? Function(String sessionId)? agentStatusOf,
    ResumeUsage? usage,
    void Function(ResumeDecision decision)? onDecision,
    UsageLimitSettings Function()? usageLimitSettings,
    void Function(InboxItem item)? raise,
    void Function(UsageLimitNotice notice)? noticeUsageLimit,
    AgentTerminalOpener? openAgent,
    bool Function(ExecutionEnvironment environment)? reachesBox,
    AcpRuntimeFactory? acpRuntimes,
    WorktreeService? worktrees,
    AcpStartAuth Function(AgentInstallation installation, AcpLaunchSpec spec)?
    acpAuth,
    StepCommandRunner? stepCommands,
    StepWebhookPoster? stepWebhooks,
    GithubApi? Function(Automation automation)? githubApi,
    GithubClient? githubClient,
    Future<String?> Function(EnvironmentPath directory)? branchOf,
    Duration? githubSweepEvery,
  }) : _db = database,
       _tell = tell,
       _registry = registry,
       _log = log ?? _ignore,
       _raise = raise {
    final now = _now = clock ?? _utcNow;
    final ids = _newId = newId ?? newUuid;
    final automations = ToldAutomations(AutomationDao(database), _told);
    final resumes = ToldResumes(ScheduledResumeDao(database), (change) {
      _told(change);
      _resumeMoved();
    });
    _resumeRows = resumes;
    final projectChecks = ProjectCheckDao(database);
    final sessions = SessionDao(database);
    final rows = CheckoutRows(database);
    facts = DaemonCheckoutFacts(
      rows,
      windows: windows,
      remote: remote,
      reachesBox: reachesBox,
    );
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
        remote: facts.remoteRunnerFor,
        environmentOf: rows.environment,
      ),
      recorder: CommandCheckRecorder(
        StoreVerificationRecords(
          VerificationDao(database),
          onRecorded: (run) => tell([VerificationRunChanged(run)]),
        ),
        VerificationArtifactStore(
          Directory(p.join(dataDirectory, 'verification')),
        ),
        newId: () => verificationRunId(now()),
        now: now,
        onChanged: _changed,
      ),
      now: now,
      results: CheckResultDao(database),
      onChanged: _changed,
      log: _log,
    );
    checks = checkRunner;
    final preflight = UnattendedPreflight(facts: facts);
    late final HostedAgentLauncher launcher;
    final runner = _runner = AutomationRunner(
      automations: automations,
      preflight: preflight,
      facts: facts,
      checkpoints:
          checkpoints ??
          DaemonBaseCheckpoint(
            CheckpointService(
              // A box's checkout is checkpointed over its own connection.
              runnerFactory: remote ?? const CommandRunnerFactory(),
              environmentOf: rows.environment,
              records: StoreCheckpointRecords(
                CheckpointDao(database),
                onRecorded: (c) => tell([CheckpointRecorded(c)]),
              ),
              clock: _FunctionClock(now),
              newId: ids,
            ),
          ),
      launcher: launcher = HostedAgentLauncher(
        registry: registry,
        sessions: sessions,
        mcp: mcp,
        now: now,
        newId: ids,
        hostEnvironment: hostEnvironment,
        onRowWritten: sessionWritten,
        environmentOf: rows.environment,
        // One of the server's terminals, so `terminal_list` shows the run.
        openAgent: openAgent,
        onLaunched: (sessionId, agentId, directory) => firstRunPrompts.follow(
          sessionId: sessionId,
          agentId: agentId,
          directory: directory,
        ),
        acpRuntimes: acpRuntimes,
        worktrees: worktrees,
        acpAuth: acpAuth,
      ),
      now: now,
      newId: ids,
      onChanged: _changed,
    );
    // A row the server runs over ACP, while its runtime lives.
    AcpSessionRuntime? liveAcp(String sessionId) {
      final runtime = registry.findAcp(hostSessionIdOf(sessionId));
      return runtime == null || runtime.lifecycle.hasEnded ? null : runtime;
    }

    final resumeFiring = ServerResumeRunner(
      resumes: resumes,
      sessionOf: sessions.getById,
      facts: facts,
      preflight: preflight,
      launcher: () => launcher,
      runningOf: (sessionId) {
        final session = registry.find(hostSessionIdOf(sessionId));
        return session == null || session.lifecycle.hasEnded ? null : session;
      },
      close: (sessionId) async {
        final id = hostSessionIdOf(sessionId);
        if (registry.findProcess(id) != null) await registry.close(id);
      },
      statusOf: agentStatusOf,
      promptOf: (sessionId) => switch (liveAcp(sessionId)) {
        final runtime? => runtime.send,
        null => null,
      },
      usage: usage,
      onDecision: onDecision,
      now: now,
    );
    _resumes = resumeFiring;
    scheduler = AutomationScheduler(
      automations: automations,
      resumes: resumes,
      sessionOf: sessions.getById,
      firing: DaemonAutomationFiring(
        local: runner,
        facts: facts,
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
    HostSession? running(String sessionId) {
      final session = registry.find(hostSessionIdOf(sessionId));
      return session == null || session.lifecycle.hasEnded ? null : session;
    }

    final followUps = _followUps = AutomationFollowUps(
      automations: automations,
      resumes: resumes,
      repositoryName: (id) => facts.repository(id)?.name ?? 'this checkout',
      notify: (automation, run, text, {required failed}) {
        final file = raise;
        if (file == null) {
          throw StateError('This server files no notifications.');
        }
        final sessionId = run.sessionId ?? run.eventSessionId;
        final session = sessionId == null ? null : sessions.getById(sessionId);
        final agentId = session == null
            ? null
            : rows.installation(session.agentInstallationId)?.agentId;
        final external = session?.externalSessionId;
        file(
          InboxItem(
            session: WatchedSession(
              key: AgentSessionKey(
                agentId ?? 'automation',
                external == null || external.isEmpty
                    ? session?.id ?? run.id
                    : external,
              ),
              label: session?.title ?? automation.name,
              openId: session?.id ?? '',
              imported: false,
            ),
            kind: failed ? InboxItemKind.checksFailed : InboxItemKind.finished,
            at: now(),
            id: 'automation:${run.id}',
            detail: text,
          ),
        );
      },
      now: now,
      newId: ids,
      onChanged: _changed,
      commands:
          stepCommands ??
          ServerStepCommands(facts: facts, sessionOf: sessions.getById),
      webhooks: stepWebhooks ?? ServerStepWebhooks(),
    );
    github = DaemonGithub(
      dao: AutomationDao(database),
      automations: automations,
      scheduler: scheduler,
      followUps: followUps,
      resumes: resumes,
      facts: facts,
      liveSessions: sessions.getClaimingLive,
      isRunning: (id) => running(id) != null || liveAcp(id) != null,
      start: (automation, note, variables) => startWebhookRun(
        automation,
        note,
        startedBy: AutomationRunCause.github,
        variables: variables,
      ),
      now: now,
      newId: ids,
      branchOf: branchOf,
      apiFor: githubApi,
      github: githubClient,
      local: remote,
      sweepEvery: githubSweepEvery,
      log: _log,
    );
    eventRules = ServerEventRules(
      automations: automations,
      scheduler: scheduler,
      preflight: preflight,
      sessionOf: sessions.getById,
      isLive: (id) => running(id) != null || liveAcp(id) != null,
      statusOf: (id) => agentStatusOf?.call(id)?.report,
      now: now,
      newId: ids,
      log: _log,
      afterRun: followUps.after,
    );
    usageLimits = ServerUsageLimits(
      sessionOf: sessions.getById,
      installationOf: rows.installation,
      resumes: resumes,
      preflight: preflight,
      usage: usage,
      settings:
          usageLimitSettings ??
          () => usageLimitSettingsFrom(database.readMetadata('settings.v1')),
      raise: raise ?? (_) {},
      notice: noticeUsageLimit ?? (_) {},
      isLive: (id) => running(id) != null || liveAcp(id) != null,
      onArmed: _changed,
      now: now,
      newId: ids,
      log: _log,
    );
    final runChecks = DaemonRunChecks(
      checks: checkRunner,
      facts: facts,
      automations: automations,
      sessionOf: sessions.getById,
      followUps: followUps,
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
  }

  final AppDatabase _db;
  final void Function(List<DataChange> changes) _tell;
  final SessionRegistry _registry;
  late final DateTime Function() _now;
  late final String Function() _newId;
  late final AutomationFollowUps _followUps;
  final void Function(String message) _log;
  late final SessionDao _sessions;
  late final AutomationRecords _automations;
  final _pending = <DataChange>[];

  /// One write this server made itself; told with the rest of its turn.
  void _told(DataChange change) {
    if (_pending.isEmpty) {
      scheduleMicrotask(() {
        final batch = [..._pending];
        _pending.clear();
        _tell(batch);
      });
    }
    _pending.add(change);
  }

  /// A client wrote automation rows: re-arm, and start what can start.
  void written() {
    unawaited(_reconcile());
    _resumeMoved();
  }

  /// Told after any resume row moved — a client's write included — so the
  /// queues it holds look again.
  void Function()? resumesMoved;
  var _resumeMoving = false;

  void _resumeMoved() {
    if (_resumeMoving || _stopped) return;
    _resumeMoving = true;
    scheduleMicrotask(() {
      _resumeMoving = false;
      if (!_stopped) resumesMoved?.call();
    });
  }

  /// The resume waiting or firing for [sessionId], or null.
  ScheduledResume? liveResumeFor(String sessionId) =>
      _resumeRows.liveFor(sessionId);

  /// The server's session queue, which resumes then send through.
  set resumeQueue(ResumeQueue? queue) => _resumes.queue = queue;

  /// GitHub automations: polled here, each item answered once.
  late final DaemonGithub github;

  final void Function(InboxItem item)? _raise;

  /// Files [proposal] in the inbox: an agent proposed it, and it does
  /// nothing until a person turns it on. Filed again at every start, since
  /// the inbox is not kept across one.
  void fileProposal(Automation proposal) {
    final raise = _raise;
    if (raise == null || !proposal.isProposed) return;
    final sessionId = proposal.proposedSessionId;
    final session = sessionId == null ? null : _sessions.getById(sessionId);
    raise(
      InboxItem(
        session: WatchedSession(
          key: AgentSessionKey('automation', 'proposal:${proposal.id}'),
          label: session?.title ?? proposal.name,
          openId: session?.id ?? '',
          imported: false,
        ),
        kind: InboxItemKind.automationProposed,
        at: _now(),
        id: proposalInboxId(proposal.id),
        detail:
            '${proposal.proposedBy} proposed an automation: '
            '"${proposal.name}". It does nothing until you turn it on.',
      ),
    );
  }

  /// Event rules answered here (slice 5c): a turn finished or failed.
  late final ServerEventRules eventRules;

  /// Usage limits noticed here (slice 5c): filed, and a resume armed or
  /// offered as Settings says.
  late final ServerUsageLimits usageLimits;

  /// One status move the server's attention keeps — every session's, not
  /// only this server's own — for the event rules and the usage-limit watch.
  void observeStatus(SessionStatusEntry entry) {
    if (_stopped) return;
    eventRules.observe(entry);
    usageLimits.observe(entry);
  }

  late final ToldResumes _resumeRows;

  /// Cancels [sessionId]'s armed resume, saying [reason]: null when none was
  /// waiting, or it is already firing.
  ScheduledResume? cancelResumeOf(String sessionId, String reason) {
    final live = _resumeRows.liveFor(sessionId);
    if (live == null || live.state == ScheduledResumeState.firing) return null;
    return scheduler.endResume(live, ScheduledResumeState.cancelled, reason);
  }

  /// Fires scheduled resumes at this server.
  late final ServerResumeRunner _resumes;
  late final DaemonCheckoutFacts facts;
  late final AutomationScheduler scheduler;
  late final AutomationRunSettler settler;
  late final ProjectCheckRunner checks;
  late final AutomationRunner _runner;

  /// One webhook call's run: [automation], its prompt already filled, started
  /// now through the same gate, base checkpoint and launch a scheduled run
  /// takes — never queued, since its caller is waiting for the answer.
  Future<AutomationRun> startWebhookRun(
    Automation automation,
    String note, {
    AutomationRunCause? startedBy,
    Map<String, String> variables = const {},
  }) {
    final at = DateTime.now().toUtc();
    final checkout = facts.repository(automation.repositoryId)?.path;
    if (checkout != null && !facts.startsAgentsIn(checkout)) {
      final run = AutomationRun(
        id: newUuid(),
        automationId: automation.id,
        scheduledFor: at,
        firedAt: at,
        state: AutomationRunState.failed,
        reason:
            'This checkout is on ${facts.describeEnvironment(checkout)}, '
            'where this server cannot start agents, so nothing was started.',
        finishedAt: at,
        startedBy: startedBy,
        variables: variables,
      );
      _automations.insertRun(run);
      return Future.value(run);
    }
    return _runner.start(
      automation,
      at,
      note: note,
      startedBy: startedBy,
      variables: variables,
    );
  }

  /// Run now: the run a scheduled one would be, gated the same, queued behind
  /// its checkout when that is busy — a person's act, so a paused automation
  /// runs too. A webhook runs with sample values for its call's fields.
  @override
  Future<AutomationRun> runNow(String id) async {
    final automation =
        _automations.getById(id) ??
        (throw DataRefused.notFound('no automation with id $id'));
    final at = _now();
    const note = 'Started with Run now.';
    switch (automation.trigger?.action) {
      case AutomationEventAction.messageSession:
        throw const DataRefused.invalid(
          'This one tells the session an event came from, and Run now has '
          'no such session. A dry run shows what it would send.',
        );
      case AutomationEventAction.notifyOnly:
        final run = AutomationRun(
          id: _newId(),
          automationId: id,
          scheduledFor: at,
          firedAt: at,
          state: AutomationRunState.finished,
          reason: note,
          finishedAt: at,
          startedBy: AutomationRunCause.runNow,
        );
        _automations.insertRun(run);
        await _followUps.after(run);
        return _automations.runById(run.id) ?? run;
      case AutomationEventAction.startSession || null:
        break;
    }
    if (automation.isWebhook) {
      final sample = webhookSampleBody(
        webhookTemplateFields(automation.prompt),
      );
      return startWebhookRun(
        automation.copyWith(
          prompt: fillWebhookTemplate(automation.prompt, sample).prompt,
        ),
        'Started with Run now, with sample values for the call\'s fields.',
        startedBy: AutomationRunCause.runNow,
      );
    }
    final queued = scheduler.queueEventRun(
      automation,
      AutomationRun(
        id: _newId(),
        automationId: id,
        scheduledFor: at,
        firedAt: at,
        state: AutomationRunState.queued,
        reason: automation.isGithub
            ? 'Started with Run now, with sample values for GitHub\'s fields.'
            : note,
        startedBy: AutomationRunCause.runNow,
        // No pull request's branch: a sample has none to check out.
        variables: automation.isGithub
            ? {
                for (final name in kGithubVariables.keys)
                  if (name != 'github.pr.branch') name: 'example',
              }
            : const {},
      ),
    );
    await scheduler.drain(automation.repositoryId);
    return _automations.runById(queued.id) ?? queued;
  }

  /// A waiting run is let go; a running one's session is ended, which
  /// settles it as stopped by you; one whose checks are running has them
  /// stopped, each recorded as cancelled.
  @override
  Future<AutomationRun> cancelRun(String runId) async {
    final run =
        _automations.runById(runId) ??
        (throw DataRefused.notFound('no automation run with id $runId'));
    switch (run.state) {
      case AutomationRunState.queued:
        _automations.updateRun(
          run.copyWith(
            state: AutomationRunState.failed,
            reason: 'Cancelled by you before it started.',
            finishedAt: _now(),
          ),
        );
        _changed();
      case AutomationRunState.running:
        final sessionId = run.sessionId;
        final hosted = sessionId == null ? null : hostSessionIdOf(sessionId);
        if (hosted == null || _registry.findProcess(hosted) == null) {
          throw const DataRefused.invalid(
            'Its session is not one this server runs, so it cannot be ended '
            'from here. End it where it runs.',
          );
        }
        await _registry.close(hosted);
      case _ when checks.cancel(runId):
        await checks.drain();
      case _:
        throw const DataRefused.invalid('That run has already ended.');
    }
    return _automations.runById(runId) ?? run;
  }

  /// Whether a run holds [automation]'s checkout now.
  bool checkoutBusy(Automation automation) => _automations.liveRuns().any(
    (run) =>
        run.state == AutomationRunState.running &&
        _automations.getById(run.automationId)?.repositoryId ==
            automation.repositoryId,
  );

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
  var _arming = false;

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
    carryChecksIntoSteps();
    settler.sweep(owns: _ownsSession);
    _resumes.failInterrupted();
    await scheduler.start();
    github.startPolling();
    AutomationDao(_db).proposed().forEach(fileProposal);
  }

  /// Gives each "Check the result" step that names no command its checkout's
  /// project checks, which is what it ran before a check carried its own.
  /// Once: a carried step has a command, so a second pass changes nothing.
  void carryChecksIntoSteps() {
    final dao = AutomationDao(_db);
    final checks = ProjectCheckDao(_db);
    for (final automation in dao.getAll()) {
      final carried = carryProjectChecks(
        automation.steps,
        checks.forRepository(automation.repositoryId),
      );
      if (carried == null) continue;
      dao.update(automation.copyWith(steps: carried));
      _log('carried project checks into "${automation.name}"');
      if (dao.getById(automation.id) case final row?) {
        _told(AutomationChanged(row));
      }
    }
  }

  Future<void> close() async {
    _stopped = true;
    github.close();
    firstRunPrompts.close();
    scheduler.stop();
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

  /// Many writes in one turn are one re-arm: a run that finished moves an
  /// interval's next occurrence.
  void _changed() {
    if (_arming || _stopped) return;
    _arming = true;
    scheduleMicrotask(() {
      _arming = false;
      if (!_stopped) scheduler.arm();
    });
  }

  /// `checks.run` from a client: [request]'s session's checks, run here as
  /// one verification run — or why they could not run.
  @override
  Future<SessionChecksRun> run(ChecksRun request) async {
    final session = _sessions.getById(request.sessionId);
    if (session == null) {
      throw DataRefused.notFound('no session ${request.sessionId}');
    }
    final directory = _directoryOf(session);
    if (!facts.runsChecksIn(directory)) {
      return SessionChecksRun(
        SessionChecksOutcome.refused,
        message: _notRunHere(directory),
      );
    }
    final result = await checks.runForSession(session, directory);
    return result == null
        ? const SessionChecksRun(SessionChecksOutcome.none)
        : SessionChecksRun(
            SessionChecksOutcome.ran,
            verificationRunId: result.run.id,
          );
  }

  String _notRunHere(EnvironmentPath? directory) => directory == null
      ? 'this session names no checkout to run its checks in'
      : 'this checkout is on ${facts.describeEnvironment(directory)}, which '
            'the Karmashala server cannot run commands in';

  /// Where [session]'s agent works: its worktree, its recorded directory, or
  /// its checkout.
  EnvironmentPath? _directoryOf(Session session) =>
      session.worktree ??
      session.workingDirectory ??
      facts.repository(session.repositoryId)?.path;

  /// `checks_run`, answered here — run, or refused in words; null for any
  /// other tool.
  Future<Object?>? localTool(
    String tool,
    Map<String, dynamic> arguments,
    String? callerSessionId,
  ) {
    if (tool != 'checks_run' && tool != 'checks_results') return null;
    final sessionId = (arguments['sessionId'] as String?) ?? callerSessionId;
    if (sessionId == null) return null;
    final session = _sessions.getById(sessionId);
    if (session == null) {
      return Future.error(StateError('No session $sessionId.'));
    }
    if (tool == 'checks_results') {
      // A read of what is recorded: it runs nothing, so reach does not matter.
      return Future.value(
        sessionCheckResultsReport(
          checks.latestResults(session),
          limit: (arguments['limit'] as num?)?.round() ?? 50,
        ),
      );
    }
    final directory = _directoryOf(session);
    if (!facts.runsChecksIn(directory)) {
      return Future.error(
        StateError('Nothing was checked: ${_notRunHere(directory)}.'),
      );
    }
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
