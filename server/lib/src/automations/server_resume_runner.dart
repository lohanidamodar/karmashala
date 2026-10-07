import 'dart:async';
import 'dart:convert';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import 'package:agent_cli/usage.dart';
import 'package:karmashala_agent_status/karmashala_agent_status.dart'
    show HostedAgentStatus;
import 'package:karmashala_automations/records.dart';
import 'package:karmashala_automations/resumes.dart';
import 'package:karmashala_automations/runner.dart';
import 'package:karmashala_automations/scheduler.dart';
import 'package:karmashala_session/session.dart';

import '../domain/host_session.dart';
import 'daemon_agents.dart';
import 'daemon_checkout_facts.dart';
import 'hosted_agent_launcher.dart';

/// An agent account's usage, as the resume runner re-reads it before it
/// resumes: the server's one throttled service (`ServerUsage`), a fake in a
/// test.
abstract interface class ResumeUsage {
  /// The account's reading, through the throttle. Throws [UsageException].
  Future<AgentUsage> fetch(AgentInstallation installation);

  /// How long until the throttle would ask the vendor again.
  Duration dueIn(AgentInstallation installation);

  /// Whether this account's usage can be read on this server at all: its
  /// agent reports a quota with a reset time, from an environment whose
  /// credentials are here. Null when it can.
  String? unreadableBecause(AgentInstallation installation);
}

/// The session's queue as a resume sends through it (`SessionQueue`): the
/// one sender to a session, so a resume never races a queued message.
abstract interface class ResumeQueue {
  /// Sends a resume's [message] to the live session [sessionId] — its
  /// queue's head in its place when one waits. Answers the text that went;
  /// throws [StateError] in words when nothing did.
  Future<String> sendForResume(String sessionId, String message);

  /// Claims [sessionId]'s queued head to open a resumed start, or null.
  QueuedMessage? claimHeadForResume(String sessionId);

  /// How the [claimed] head went: [sent], or back at the queue's front.
  void releaseClaimed(QueuedMessage claimed, {required bool sent});
}

/// What a resume's end is filed as, for its session's record.
typedef ResumeDecision = ({
  String sessionId,
  String resumeId,
  String scheduledBy,
  String summary,
  String detail,
});

/// **A scheduled resume, fired by the server** (slice 5c) — the app's
/// `ScheduledResumeRunner`, ported: the gate again, the account's usage
/// again, then either the message typed into the session the server runs, or
/// the conversation resumed as a session the server owns. Works with no
/// client anywhere — on this machine, or on an SSH box the server reaches
/// (slice 5d); anywhere else is refused in words.
class ServerResumeRunner implements ScheduledResumeFiring {
  ServerResumeRunner({
    required this.resumes,
    required this.sessionOf,
    required this.facts,
    required this.preflight,
    required this.launcher,
    required this.runningOf,
    required this.close,
    required this.now,
    this.statusOf,
    this.promptOf,
    this.usage,
    this.onDecision,
    this.agents = const DaemonAgents(),
    this.enterDelay = const Duration(milliseconds: 150),
  });

  final ResumeRecords resumes;
  final Session? Function(String sessionId) sessionOf;
  final DaemonCheckoutFacts facts;
  final UnattendedPreflight preflight;

  /// Starts the resumed conversation; null until MCP is up (refused then).
  final HostedAgentLauncher? Function() launcher;

  /// The running session this server holds for a row, or null.
  final HostSession? Function(String sessionId) runningOf;

  /// How to send a turn to a row the server runs over a protocol (no
  /// terminal to type into), or null when it runs none there.
  final Future<void> Function(String message)? Function(String sessionId)?
  promptOf;

  /// Ends the session the server runs for a row (a resume armed under
  /// another mode restarts it).
  final Future<void> Function(String sessionId) close;

  /// What the agent in a row the server runs is doing, or null.
  final HostedAgentStatus? Function(String sessionId)? statusOf;

  /// The account's usage; null goes by the time alone, and says so.
  final ResumeUsage? usage;

  /// Files a resume that went ahead in its session's record.
  final void Function(ResumeDecision decision)? onDecision;
  final DaemonAgents agents;
  final DateTime Function() now;

  /// The pause between a typed message and its Enter (a TUI reads text and
  /// CR in one read as a paste).
  final Duration enterDelay;

  /// Set once the scheduler exists: every end goes through it, so every
  /// client is told how the resume ended.
  late AutomationScheduler scheduler;

  /// Set once the server's queue exists; before then a message is typed or
  /// prompted directly.
  ResumeQueue? queue;

  /// Fails every row a server that stopped mid-resume left `firing`: a second
  /// try could send the message twice. Run before the scheduler starts.
  void failInterrupted() {
    for (final resume in resumes.inState(ScheduledResumeState.firing)) {
      scheduler.endResume(
        resume,
        ScheduledResumeState.failed,
        'Karmashala stopped while this was being resumed. It was not tried '
        'again, because a second try could send the message twice.',
      );
    }
  }

  @override
  Future<void> fire(ScheduledResume resume, {String note = ''}) async {
    // Claimed in the store, so two ticks cannot both resume one session.
    final claimed = resumes.transition(
      resume.id,
      from: resume.state,
      to: ScheduledResumeState.firing,
    );
    if (!claimed) return;
    final firing = resume.copyWith(state: ScheduledResumeState.firing);
    try {
      await _run(firing, note);
    } on Object catch (error) {
      _finish(
        firing,
        ScheduledResumeState.failed,
        'The scheduled resume stopped on an error: $error',
      );
    }
  }

  Future<void> _run(ScheduledResume resume, String note) async {
    final session = sessionOf(resume.sessionId);
    if (session == null) {
      _finish(
        resume,
        ScheduledResumeState.failed,
        'The session is no longer in the workspace.',
      );
      return;
    }
    if (session.isArchived) {
      _finish(
        resume,
        ScheduledResumeState.cancelled,
        'The session was archived, so it was left alone.',
      );
      return;
    }
    final live =
        runningOf(session.id) != null || promptOf?.call(session.id) != null;
    if (live && !resume.liveWhenScheduled) {
      _finish(
        resume,
        ScheduledResumeState.cancelled,
        'You resumed this session yourself before its time, so the scheduled '
        'resume was cancelled and nothing was sent.',
      );
      return;
    }
    final repository = facts.repository(session.repositoryId);
    final directory = session.worktree ?? repository?.path;
    if (repository != null && !facts.startsAgentsIn(directory)) {
      _finish(
        resume,
        ScheduledResumeState.failed,
        'This session is on ${facts.describeEnvironment(directory!)}, which '
        'this Karmashala server does not reach, so nothing was resumed or '
        'sent.',
      );
      return;
    }
    final refusal = preflight.refusalForResume(
      session,
      permissionMode: resume.permissionMode,
    );
    if (refusal != null) {
      _finish(resume, ScheduledResumeState.failed, refusal.reason);
      return;
    }

    var usageNote = '';
    if (resume.windowLabel != null) {
      final verdict = await _checkUsage(resume, session);
      if (verdict == null) return;
      usageNote = verdict;
    }

    if (live && !_needsRestart(session, resume)) {
      await _sendToLive(resume, session, [note, usageNote]);
    } else {
      await _resumeAndSend(resume, session, live, [note, usageNote]);
    }
  }

  /// Re-reads the account. A note to carry when the resume may go ahead, or
  /// null when the row was rescheduled or ended here.
  Future<String?> _checkUsage(ScheduledResume resume, Session session) async {
    final installation = facts.installation(session.agentInstallationId);
    final service = usage;
    if (installation == null ||
        service == null ||
        service.unreadableBecause(installation) != null) {
      return 'Usage could not be re-read here, so this went by the time alone.';
    }
    final accountKey = usageAccountKey(installation);
    AgentUsage reading;
    try {
      reading = await service.fetch(installation);
    } on UsageException catch (error) {
      return 'Usage could not be re-read (${error.message}), so this went by '
          'the reset time the provider gave.';
    }
    final at = now();
    final switched =
        accountKey != resume.accountKey ||
        (resume.accountEmail != null &&
            reading.email != null &&
            reading.email != resume.accountEmail);
    final switchedNote = switched
        ? 'The account this session uses changed since this was scheduled, so '
              'the new one was checked. '
        : '';
    switch (checkReset(reading, now: at)) {
      case ResetConfirmed():
        return switched ? switchedNote.trim() : '';
      case ReadingPredatesReset():
        final attempts = resume.attempts + 1;
        if (attempts >= kResumeMaxStaleReadings) {
          _finish(
            resume.copyWith(attempts: attempts),
            ScheduledResumeState.failed,
            'Gave up after $attempts checks: no reading newer than the reset '
            'arrived. Nothing was resumed or sent — schedule it again once '
            'the limit is back.',
          );
          return null;
        }
        final wait = service.dueIn(installation) + kUsageResetGrace;
        final again = at.add(
          wait < const Duration(seconds: 30)
              ? const Duration(seconds: 30)
              : wait,
        );
        _reschedule(
          resume,
          fireAt: again,
          resetsAt: resume.resetsAt,
          attempts: attempts,
          accountKey: accountKey,
          accountEmail: reading.email,
          reason:
              '${switchedNote}The last usage reading predates the reset. '
              'Looking again at ${formatResumeClock(again, at)}.',
        );
        return null;
      case StillLimited(:final label, :final until):
        final attempts = resume.attempts + 1;
        final again = nextResumeAttempt(
          attempts: attempts,
          now: at,
          until: until,
        );
        _reschedule(
          resume,
          fireAt: again,
          resetsAt: until,
          attempts: attempts,
          accountKey: accountKey,
          accountEmail: reading.email,
          reason:
              '${switchedNote}Still limited: the $label window '
              '${until == null ? 'names no reset yet' : 'resets '
                        '${formatResumeClock(until, at)}'}. '
              'Trying again at ${formatResumeClock(again, at)}.',
        );
        return null;
    }
  }

  /// Whether the running session is under another mode than the one this
  /// resume was armed with — the mode the gate passed is the one it runs in.
  bool _needsRestart(Session session, ScheduledResume resume) {
    final chosen = resume.permissionMode;
    if (chosen == null) return false;
    final agentId = facts.installation(session.agentInstallationId)?.agentId;
    if (agentId == null) return false;
    return agents.permissionOf(agentId, chosen).canonical !=
        agents.permissionOf(agentId, session.permissionMode).canonical;
  }

  Future<void> _sendToLive(
    ScheduledResume resume,
    Session session,
    List<String> notes,
  ) async {
    final report = statusOf?.call(session.id)?.report;
    if (report != null && report.status == AgentActivityStatus.working) {
      _finish(
        resume,
        ScheduledResumeState.cancelled,
        'The session was already working when its time came, so nothing was '
        'sent.',
      );
      return;
    }
    if (!resume.sendsMessage) {
      _finish(
        resume,
        ScheduledResumeState.done,
        _join([
          'The session was already open; nothing was set to be sent.',
          ...notes,
        ]),
      );
      return;
    }
    if (report != null && (report.hasOpenPrompt || report.hasOpenQuestion)) {
      _finish(
        resume,
        ScheduledResumeState.failed,
        'The agent has a prompt open, and a message typed there would answer '
        'it. Nothing was sent.',
      );
      return;
    }
    final message = resume.message.trim();
    if (queue case final queue?) {
      final String sent;
      try {
        sent = await queue.sendForResume(session.id, message);
      } on StateError catch (refused) {
        _finish(
          resume,
          ScheduledResumeState.failed,
          'The session did not take the message: ${refused.message}',
        );
        return;
      }
      _finish(
        resume,
        ScheduledResumeState.done,
        _join([
          sent == message
              ? 'The session was already open, and sent "$message".'
              : 'The session was already open, and sent the queued message '
                    '"$sent" in place of "$message".',
          ...notes,
        ]),
        sent: sent,
      );
      return;
    }
    final running = runningOf(session.id);
    if (running == null) {
      if (promptOf?.call(session.id) case final prompt?) {
        try {
          await prompt(message);
        } on StateError catch (refused) {
          _finish(
            resume,
            ScheduledResumeState.failed,
            'The session did not take the message: ${refused.message}',
          );
          return;
        }
        _finish(
          resume,
          ScheduledResumeState.done,
          _join([
            'The session was already open, and sent "$message".',
            ...notes,
          ]),
          sent: message,
        );
        return;
      }
    }
    if (running == null || !running.typeAsHost(utf8.encode(message))) {
      _finish(
        resume,
        ScheduledResumeState.failed,
        'The session had no live terminal to type into, so nothing was sent.',
      );
      return;
    }
    // Enter after a pause: text and CR in one read is a paste, not a submit.
    unawaited(
      Future<void>.delayed(enterDelay, () {
        runningOf(session.id)?.typeAsHost(utf8.encode('\r'));
      }),
    );
    _finish(
      resume,
      ScheduledResumeState.done,
      _join(['The session was already open, and sent "$message".', ...notes]),
      sent: message,
    );
  }

  Future<void> _resumeAndSend(
    ScheduledResume resume,
    Session session,
    bool live,
    List<String> notes,
  ) async {
    final repository = facts.repository(session.repositoryId);
    final installation = facts.installation(session.agentInstallationId);
    final externalId = session.externalSessionId;
    if (repository == null || installation == null) {
      _finish(
        resume,
        ScheduledResumeState.failed,
        'The checkout or the agent went away just before the resume.',
      );
      return;
    }
    if (externalId == null || externalId.isEmpty) {
      _finish(
        resume,
        ScheduledResumeState.failed,
        'This session recorded no conversation to resume.',
      );
      return;
    }
    if (live) {
      final report = statusOf?.call(session.id)?.report;
      if (report != null && report.status == AgentActivityStatus.working) {
        _finish(
          resume,
          ScheduledResumeState.cancelled,
          'The session was already working when its time came, so nothing was '
          'sent.',
        );
        return;
      }
    }
    final start = launcher();
    if (start == null) {
      _finish(
        resume,
        ScheduledResumeState.failed,
        'The Karmashala server could not start agents yet (its agent tools '
        'were not up), so nothing was resumed.',
      );
      return;
    }
    // The message rides the command line where the agent takes one there:
    // the CLI submits it when it is ready, nothing typed at a starting TUI.
    // Over ACP the launcher sends it as the first prompt instead.
    final descriptor = agents.descriptorOf(installation.agentId);
    final takesOpening =
        descriptor != null &&
        (descriptor.acp != null || descriptor.launch.acceptsPromptArgument);
    // A message queued while the limit held opens it in the resume's place.
    final claimed = takesOpening ? queue?.claimHeadForResume(session.id) : null;
    final message = claimed?.text ?? resume.message.trim();
    final asArgument = message.isNotEmpty && takesOpening;
    try {
      if (live) {
        // Open under another mode than the one armed. Every refusal came
        // before this, which cannot be undone.
        await close(session.id);
      }
      await start.start(
        HostedLaunch(
          repository: repository,
          installation: installation,
          title: session.title,
          resuming: sessionOf(session.id) ?? session,
          prompt: asArgument ? message : null,
          permissionMode: resume.permissionMode == null
              ? null
              : agents
                    .permissionOf(installation.agentId, resume.permissionMode)
                    .canonical,
        ),
      );
    } on Object catch (error) {
      if (claimed != null) queue?.releaseClaimed(claimed, sent: false);
      _finish(
        resume,
        ScheduledResumeState.failed,
        'The session could not be resumed: $error',
      );
      return;
    }
    if (claimed != null) {
      queue?.releaseClaimed(claimed, sent: true);
      final instead = resume.message.trim();
      _finish(
        resume,
        ScheduledResumeState.done,
        _join([
          'Resumed, and sent the queued message "$message"'
              '${instead.isEmpty ? '' : ' in place of "$instead"'}.',
          ...notes,
        ]),
        sent: message,
      );
      return;
    }
    if (message.isEmpty) {
      _finish(
        resume,
        ScheduledResumeState.done,
        _join(['Resumed; nothing was set to be sent.', ...notes]),
      );
      return;
    }
    _finish(
      resume,
      ScheduledResumeState.done,
      asArgument
          ? _join(['Resumed, and sent "$message".', ...notes])
          : _join([
              'Resumed. This agent takes no opening message on its command '
                  'line, so "$message" was not sent — say it in the session.',
              ...notes,
            ]),
      sent: asArgument ? message : null,
    );
  }

  void _reschedule(
    ScheduledResume resume, {
    required DateTime fireAt,
    required String reason,
    DateTime? resetsAt,
    int? attempts,
    String? accountKey,
    String? accountEmail,
  }) {
    resumes.update(
      resume.copyWith(
        state: ScheduledResumeState.pending,
        fireAt: fireAt.toUtc(),
        resetsAt: resetsAt?.toUtc(),
        clearResetsAt: resetsAt == null,
        reason: reason,
        attempts: attempts,
        accountKey: accountKey,
        accountEmail: accountEmail,
      ),
    );
  }

  void _finish(
    ScheduledResume resume,
    ScheduledResumeState state,
    String reason, {
    String? sent,
  }) {
    scheduler.endResume(resume, state, reason);
    if (state != ScheduledResumeState.done) return;
    final at = now();
    onDecision?.call((
      sessionId: resume.sessionId,
      resumeId: resume.id,
      scheduledBy: resume.scheduledBy,
      summary: sent == null
          ? 'Resumed on schedule, with nothing sent'
          : 'Resumed on schedule and sent "$sent"',
      detail:
          'Scheduled by ${resume.scheduledBy} at '
          '${formatResumeClock(resume.scheduledAt, at)} for '
          '${resume.windowLabel == null ? 'a chosen time' : 'the '
                    '${resume.windowLabel} reset'}.',
    ));
  }

  static String _join(List<String> parts) =>
      parts.where((part) => part.trim().isNotEmpty).join(' ');
}

/// `14:05` today, `Tue 14:05` otherwise, on this machine's clock — the
/// desktop's usage chip's words (`formatResetClock`).
String formatResumeClock(DateTime when, DateTime now) {
  final local = when.toLocal();
  final here = now.toLocal();
  final clock =
      '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
  if (local.year == here.year &&
      local.month == here.month &&
      local.day == here.day) {
    return clock;
  }
  const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  return '${names[local.weekday - 1]} $clock';
}

/// [ResumeUsage] over the server's own throttled service.
class ServiceResumeUsage implements ResumeUsage {
  ServiceResumeUsage(
    this.service, {
    required this.environments,
    this.registry = AgentRegistry.builtIn,
  });

  final AgentUsageService service;
  final List<ExecutionEnvironment> Function() environments;
  final AgentRegistry registry;

  @override
  Future<AgentUsage> fetch(AgentInstallation installation) =>
      service.fetch(installation, environments());

  @override
  Duration dueIn(AgentInstallation installation) => service.dueIn(installation);

  @override
  String? unreadableBecause(AgentInstallation installation) {
    final usage = registry.adapterFor(installation.agentId)?.usage;
    if (usage == null || !usage.reportsResetTime) {
      return 'the agent reports no quota with a reset time';
    }
    ExecutionEnvironment? environment;
    for (final candidate in environments()) {
      if (candidate.id == installation.environmentId) environment = candidate;
    }
    if (environment == null || !cliStoreIsReachable(environment.kind)) {
      return "the agent's sign-in is on another machine";
    }
    return null;
  }
}
