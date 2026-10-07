import 'dart:async';

import 'package:agent_cli/process.dart';
import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/github.dart';
import 'package:karmashala_automations/records.dart';
import 'package:karmashala_automations/resumes.dart';
import 'package:karmashala_automations/runner.dart';
import 'package:karmashala_automations/runs.dart';
import 'package:karmashala_automations/scheduler.dart';
import 'package:karmashala_automations/store.dart';
import 'package:karmashala_session/session.dart';

import '../daemon_checkout_facts.dart';
import 'gh_github_api.dart';

/// Set to `off` and the server never polls GitHub for automations.
const String kGithubPollVariable = 'KARMASHALA_GITHUB_POLL';

/// How often the poller looks for an automation that is due its look.
const Duration kGithubSweepEvery = Duration(seconds: 30);

/// GitHub automations in the server: the poller on a timer, and what each
/// event it passes on does — a new agent in a worktree on the pull request's
/// branch, the session that already owns that branch told, or only the steps.
class DaemonGithub {
  DaemonGithub({
    required this.dao,
    required this.automations,
    required this.scheduler,
    required this.followUps,
    required this.resumes,
    required this.facts,
    required this.liveSessions,
    required this.isRunning,
    required this.start,
    required this.now,
    required this.newId,
    this.branchOf,
    GithubApi? Function(Automation automation)? apiFor,
    CommandRunnerFactory? local,
    this.sweepEvery,
    this.log,
  }) : _local = local ?? const CommandRunnerFactory() {
    poller = GithubPoller(
      dao: dao,
      apiFor: apiFor ?? _ghFor,
      fire: fire,
      now: now,
      log: log,
    );
  }

  final AutomationDao dao;
  final AutomationRecords automations;
  final AutomationScheduler scheduler;
  final AutomationFollowUps followUps;
  final ResumeRecords resumes;
  final DaemonCheckoutFacts facts;

  /// The sessions that may still be live, any checkout.
  final List<Session> Function() liveSessions;

  /// Whether this server runs [String]'s session now, so a message reaches it.
  final bool Function(String sessionId) isRunning;

  /// Starts one run now: the gate, the base checkpoint, the launch.
  final Future<AutomationRun> Function(
    Automation automation,
    String note,
    Map<String, String> variables,
  )
  start;
  final DateTime Function() now;
  final String Function() newId;

  /// The branch checked out at a directory; null asks git.
  final Future<String?> Function(EnvironmentPath directory)? branchOf;
  final Duration? sweepEvery;
  final void Function(String message)? log;
  final CommandRunnerFactory _local;
  late final GithubPoller poller;
  final Map<String, GhGithubApi> _apis = {};
  Timer? _timer;

  void startPolling() {
    final every = sweepEvery;
    if (every == null) return;
    _timer = Timer.periodic(every, (_) => unawaited(poller.sweep()));
  }

  void close() => _timer?.cancel();

  CommandRunner? _runnerFor(EnvironmentPath path) {
    final place = facts.rows.environment(path.environmentId);
    if (place == null || !facts.runsChecksIn(path)) return null;
    return facts.remoteRunnerFor(path) ?? _local.forEnvironment(place);
  }

  GithubApi? _ghFor(Automation automation) {
    final checkout = facts.repository(automation.repositoryId)?.path;
    if (checkout == null) return null;
    final runner = _runnerFor(checkout);
    if (runner == null) return null;
    final key = '${automation.id} ${checkout.environmentId} ${checkout.path}';
    return _apis[key] ??= GhGithubApi(runner, checkout);
  }

  Future<String?> _branch(EnvironmentPath directory) async {
    final ask = branchOf;
    if (ask != null) return ask(directory);
    final runner = _runnerFor(directory);
    if (runner == null) return null;
    try {
      final result = await runner.run(
        CommandRequest(
          executable: 'git',
          arguments: const ['rev-parse', '--abbrev-ref', 'HEAD'],
          workingDirectory: directory,
          timeout: const Duration(seconds: 20),
        ),
      );
      return result.ok ? result.stdout.trim() : null;
    } on CommandException {
      return null;
    }
  }

  /// The running session of [repositoryId] whose worktree is on [branch].
  Future<Session?> sessionOn(String repositoryId, String branch) async {
    if (branch.isEmpty) return null;
    for (final session in liveSessions()) {
      final worktree = session.worktree;
      if (session.repositoryId != repositoryId ||
          session.isArchived ||
          worktree == null ||
          !isRunning(session.id)) {
        continue;
      }
      if (await _branch(worktree) == branch) return session;
    }
    return null;
  }

  /// Acts on one event that passed [automation]'s filters.
  Future<void> fire(Automation automation, GithubEvent event) async {
    final github = automation.github!;
    final at = now();
    final run = AutomationRun(
      id: newId(),
      automationId: automation.id,
      scheduledFor: at,
      firedAt: at,
      state: AutomationRunState.running,
      reason: 'Because ${event.describe}.',
      startedBy: AutomationRunCause.github,
      variables: event.variables,
    );
    switch (github.action) {
      case AutomationEventAction.notifyOnly:
        final done = run.copyWith(
          state: AutomationRunState.finished,
          finishedAt: at,
        );
        automations.insertRun(done);
        await followUps.after(done);
        return;
      case AutomationEventAction.messageSession:
        if (github.kind.isPullRequest) {
          final session = await sessionOn(
            automation.repositoryId,
            event.branch,
          );
          if (session != null) {
            await _tell(automation, run, session, event);
            return;
          }
        }
      case AutomationEventAction.startSession:
        break;
    }
    if (github.kind.isPullRequest || automation.worktree) {
      await start(automation, run.reason, run.variables);
      return;
    }
    // In the checkout itself: behind whatever holds it, as an event's run.
    scheduler.queueEventRun(
      automation,
      run.copyWith(state: AutomationRunState.queued),
    );
    await scheduler.drain(automation.repositoryId);
  }

  Future<void> _tell(
    Automation automation,
    AutomationRun run,
    Session session,
    GithubEvent event,
  ) async {
    final at = now();
    String reason;
    var state = AutomationRunState.finished;
    if (resumes.liveFor(session.id) != null) {
      state = AutomationRunState.failed;
      reason =
          '${run.reason} A resume is already waiting for "${session.title}", '
          'so nothing was sent.';
    } else {
      resumes.replaceFor(
        ScheduledResume(
          id: newId(),
          sessionId: session.id,
          fireAt: at,
          state: ScheduledResumeState.pending,
          scheduledAt: at,
          message: fillAgentText(automation.prompt, run.variables),
          latePolicy: ResumeLatePolicy.resume,
          scheduledBy: 'automation "${automation.name}"',
        ),
        now: at,
      );
      reason =
          '${run.reason} Told "${session.title}", which is on '
          '${event.branch}.';
    }
    final done = AutomationRun(
      id: run.id,
      automationId: run.automationId,
      scheduledFor: run.scheduledFor,
      firedAt: run.firedAt,
      state: state,
      reason: reason,
      finishedAt: at,
      eventSessionId: session.id,
      startedBy: run.startedBy,
      variables: run.variables,
    );
    automations.insertRun(done);
    await followUps.after(done);
  }
}
