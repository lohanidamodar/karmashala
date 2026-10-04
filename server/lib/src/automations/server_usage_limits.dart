import 'dart:async';
import 'dart:convert';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart' show AgentInstallation;
import 'package:agent_cli/usage.dart';
import 'package:karmashala_automations/records.dart';
import 'package:karmashala_automations/resumes.dart';
import 'package:karmashala_automations/runner.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show SessionStatusEntry, UsageLimitNotice, UsageLimitOutcome;
import 'package:karmashala_notifications/attention.dart';
import 'package:karmashala_session/session.dart';

import '../acp/acp_usage_limit.dart'
    show
        hasUsageLimitWording,
        kProtocolLimitMinimumWait,
        kProtocolUsageLimitReason,
        usageLimitResetIn;
import 'server_resume_runner.dart' show ResumeUsage, formatResumeClock;

/// How old an agent's rate-limit record may be and still explain *this*
/// turn ending. Older, and it is the last thing a previous run knew.
const Duration kLimitRecordFreshness = Duration(minutes: 10);

/// What a scheduled resume says unless a person typed something else — the
/// app's default, which Settings may override (`resumeMessage`,
/// `resumeMessages` per agent).
const String kDefaultResumeMessage = 'continue';

/// What the Settings choice `onUsageLimit` says to do.
enum UsageLimitBehavior { ask, schedule, nothing }

/// The usage-limit part of a client's settings (`settings.v1`), read afresh
/// each time: the choice, and the message a resume sends.
typedef UsageLimitSettings = ({
  UsageLimitBehavior behavior,
  String Function(String agentId) resumeMessageFor,
});

/// Reads [UsageLimitSettings] out of `settings.v1`'s JSON; a missing or odd
/// value is the default (schedule; "continue"). The legacy key
/// `usageLimitBehavior` was saved on every write while `ask` was the default,
/// so only its `nothing` is taken as chosen — as the app reads it.
UsageLimitSettings usageLimitSettingsFrom(String? raw) {
  Map<String, Object?> json = const {};
  try {
    final decoded = raw == null ? null : jsonDecode(raw);
    if (decoded is Map) json = decoded.cast<String, Object?>();
  } on FormatException {
    // Defaults.
  }
  final behavior = json.containsKey('onUsageLimit')
      ? UsageLimitBehavior.values.firstWhere(
          (b) => b.name == json['onUsageLimit'],
          orElse: () => UsageLimitBehavior.schedule,
        )
      : json['usageLimitBehavior'] == UsageLimitBehavior.nothing.name
      ? UsageLimitBehavior.nothing
      : UsageLimitBehavior.schedule;
  final message = json['resumeMessage'] is String
      ? json['resumeMessage']! as String
      : kDefaultResumeMessage;
  final perAgent = json['resumeMessages'] is Map
      ? (json['resumeMessages']! as Map).cast<String, Object?>()
      : const <String, Object?>{};
  return (
    behavior: behavior,
    resumeMessageFor: (agentId) =>
        perAgent[agentId] is String ? perAgent[agentId]! as String : message,
  );
}

/// One session's turn ending on its account's usage limit.
typedef UsageLimitHit = ({
  String sessionId,
  String agentName,
  UsageWindow window,
});

/// "Codex hit its 5-hour limit. Resets 14:05." — in the server's clock.
String usageLimitSentence(UsageLimitHit hit, DateTime now) {
  final resets = hit.window.resetsAt;
  return '${hit.agentName} hit its ${hit.window.label} limit.'
      '${resets == null ? '' : ' Resets ${formatResumeClock(resets, now)}.'}';
}

/// Whether [report] is a turn that failed on [agentId]'s usage limit by the
/// agent's own word — read at once, before any usage reading confirms it.
bool endedOnUsageLimit(
  AgentStatusReport report, {
  String? agentId,
  AgentRegistry agents = AgentRegistry.builtIn,
}) {
  if (report.status != AgentActivityStatus.failed) return false;
  if (report.source == AgentStatusSource.protocol) {
    return report.failureReason == kProtocolUsageLimitReason;
  }
  if (agentId == null) return false;
  return switch (agents.adapterFor(agentId)?.usage?.limitEvidence) {
    HookFailureReasonEvidence(:final reason) => report.failureReason == reason,
    _ => false,
  };
}

/// What holds a session's queue for its limit: the resume [live] for it, or
/// a turn that just failed on the limit while none is armed yet.
QueueHold? usageLimitQueueHold({
  ScheduledResume? live,
  AgentStatusReport? report,
  String? agentId,
  AgentRegistry agents = AgentRegistry.builtIn,
}) {
  if (live != null) {
    return QueueHold(
      live.windowLabel == null ? QueueHoldKind.scheduled : QueueHoldKind.limit,
      until: live.fireAt,
    );
  }
  if (report != null &&
      endedOnUsageLimit(report, agentId: agentId, agents: agents)) {
    return const QueueHold(QueueHoldKind.limit);
  }
  return null;
}

/// **A turn that ended on a usage limit, noticed by the server** (slice 5c)
/// — the app's `UsageLimitWatcher`, moved, so a limit is noticed and a resume
/// armed with every app closed. Only from evidence the agent itself wrote, as
/// its adapter declares it: a failure hook's reason confirmed by a spent
/// window in a fresh usage reading, or the agent's own rate-limit record in
/// its state file. Once per reset per session. Filed in the inbox, then as
/// Settings says: arm a resume at the reset (`schedule`), re-arm one a
/// session had before (a done resume that waited on a window), or offer it
/// (`ask`) — a client presents the notice ([UsageLimitNoticed]).
class ServerUsageLimits {
  ServerUsageLimits({
    required this.sessionOf,
    required this.installationOf,
    required this.resumes,
    required this.preflight,
    required this.usage,
    required this.settings,
    required this.raise,
    required this.notice,
    required this.isLive,
    required this.now,
    required this.newId,
    this.onArmed,
    this.agents = AgentRegistry.builtIn,
    this.log,
  });

  final Session? Function(String sessionId) sessionOf;
  final AgentInstallation? Function(String installationId) installationOf;
  final ResumeRecords resumes;
  final UnattendedPreflight preflight;
  final ResumeUsage? usage;
  final UsageLimitSettings Function() settings;

  /// Files an item in the inbox.
  final void Function(InboxItem item) raise;

  /// Tells clients what was done ([UsageLimitNoticed]).
  final void Function(UsageLimitNotice notice) notice;

  /// Whether the server runs row [String]'s agent now.
  final bool Function(String sessionId) isLive;

  /// A resume was armed: the scheduler arms its timer.
  final void Function()? onArmed;
  final DateTime Function() now;
  final String Function() newId;
  final AgentRegistry agents;
  final void Function(String message)? log;

  /// The reset last acted on per session: one limit is one notice however
  /// many status moves follow it.
  final Map<String, DateTime> _handled = {};

  /// One status move; an idle or failed turn end is looked at after this
  /// turn (it reads usage).
  void observe(SessionStatusEntry entry) {
    if (entry.session.imported) return;
    final status = entry.report.status;
    if (status != AgentActivityStatus.idle &&
        status != AgentActivityStatus.failed) {
      return;
    }
    unawaited(
      consider(entry).catchError((Object error) {
        log?.call('usage limits: ${entry.openId} not looked at ($error)');
      }),
    );
  }

  /// What [entry] says about a limit, acted on once per reset.
  Future<void> consider(SessionStatusEntry entry) async {
    final choice = settings();
    if (choice.behavior == UsageLimitBehavior.nothing) return;
    final session = sessionOf(entry.openId);
    if (session == null || session.isArchived) return;
    final hit = await detect(session, entry);
    if (hit == null) return;
    final resets = hit.window.resetsAt;
    final at = now();
    if (resets == null || !resets.isAfter(at)) return;
    final handled = _handled[session.id];
    if (handled != null &&
        handled.difference(resets).abs() <= kResumeSameReset) {
      return;
    }
    _handled[session.id] = resets;
    // Already waiting on a resume: the limit is not news to its owner.
    if (resumes.liveFor(session.id) != null) return;

    raise(
      InboxItem(
        session: entry.session,
        kind: InboxItemKind.usageLimit,
        at: at,
        detail: usageLimitSentence(hit, at),
      ),
    );
    final agentId = installationOf(session.agentInstallationId)?.agentId;
    final message = agentId == null
        ? kDefaultResumeMessage
        : choice.resumeMessageFor(agentId);
    if (choice.behavior == UsageLimitBehavior.schedule) {
      _arm(
        hit,
        session,
        message: message,
        scheduledBy: kResumeScheduledBySetting,
        outcome: UsageLimitOutcome.scheduled,
      );
      return;
    }
    // Asked once for this session, and it worked: the limit coming back is
    // what that arrangement was for, so it is made again rather than offered.
    final last = resumes.lastEndedFor(session.id);
    if (last != null &&
        last.state == ScheduledResumeState.done &&
        last.windowLabel != null) {
      _arm(
        hit,
        session,
        message: last.message,
        permissionMode: last.permissionMode,
        notify: last.notify,
        latePolicy: last.latePolicy,
        scheduledBy: last.scheduledBy,
        outcome: UsageLimitOutcome.renewed,
      );
      return;
    }
    _tell(hit, UsageLimitOutcome.offered);
  }

  /// The limit behind [entry], or null — per agent, and only from evidence
  /// the agent itself wrote.
  Future<UsageLimitHit?> detect(
    Session session,
    SessionStatusEntry entry,
  ) async {
    final installation = installationOf(session.agentInstallationId);
    if (installation == null) return null;
    final name = agents.displayNameFor(installation.agentId);
    final evidence = agents
        .adapterFor(installation.agentId)
        ?.usage
        ?.limitEvidence;
    final at = now();
    // A protocol turn the agent refused on a limit, in its own words: a
    // spent window in a reading names the reset when one can be read, else
    // the words themselves when they carry it. A bare rate limit with a short
    // retry is a passing throttle, not a limit to resume after.
    if (entry.report.source == AgentStatusSource.protocol &&
        entry.report.failureReason == kProtocolUsageLimitReason) {
      final spent = await _spentWindow(installation, at);
      if (spent != null) {
        return (sessionId: session.id, agentName: name, window: spent);
      }
      final words = entry.report.evidence;
      final resets = usageLimitResetIn(words, at);
      if (resets == null) return null;
      if (!hasUsageLimitWording(words) &&
          resets.difference(at) < kProtocolLimitMinimumWait) {
        return null;
      }
      return (
        sessionId: session.id,
        agentName: name,
        window: UsageWindow(label: 'usage', resetsAt: resets),
      );
    }
    switch (evidence) {
      case HookFailureReasonEvidence(:final reason):
        if (entry.report.failureReason != reason) return null;
        // The same word can be a passing rate limit: only a spent window
        // makes it a usage limit, and only a reading names the reset.
        final window = await _spentWindow(installation, at);
        if (window == null) return null;
        return (sessionId: session.id, agentName: name, window: window);
      case StateFileRateLimitEvidence(:final read):
        final path = entry.session.stateFilePath;
        if (path == null || path.isEmpty) return null;
        final record = await read(path);
        if (record == null || !record.limitReached) return null;
        final recordedAt = record.recordedAt;
        if (recordedAt == null ||
            at.difference(recordedAt) > kLimitRecordFreshness) {
          return null;
        }
        final window =
            record.blocking ?? blockingWindow(record.windows, now: at)?.window;
        if (window == null) return null;
        return (sessionId: session.id, agentName: name, window: window);
      case NoUsageLimitEvidence() || null:
        return null;
    }
  }

  /// The spent window a fresh reading of [installation]'s account names, or
  /// null when there is none or no reading.
  Future<UsageWindow?> _spentWindow(
    AgentInstallation installation,
    DateTime at,
  ) async {
    final reader = usage;
    if (reader == null || reader.unreadableBecause(installation) != null) {
      return null;
    }
    final AgentUsage reading;
    try {
      reading = await reader.fetch(installation);
    } on UsageException {
      return null;
    }
    final blocking = blockingWindow(reading.windows, now: at);
    if (blocking == null || blocking.reason != BlockingWindowReason.spent) {
      return null;
    }
    return blocking.window;
  }

  void _arm(
    UsageLimitHit hit,
    Session session, {
    required String message,
    required String scheduledBy,
    required UsageLimitOutcome outcome,
    String? permissionMode,
    bool notify = true,
    ResumeLatePolicy latePolicy = ResumeLatePolicy.ask,
  }) {
    final refusal = preflight.refusalForResume(
      session,
      permissionMode: permissionMode,
    );
    if (refusal != null) {
      _tell(hit, UsageLimitOutcome.refused, refusal: refusal.reason);
      return;
    }
    final installation = installationOf(session.agentInstallationId);
    final at = now();
    final resetsAt = hit.window.resetsAt!;
    final resume = ScheduledResume(
      id: newId(),
      sessionId: session.id,
      accountKey: installation == null ? '' : usageAccountKey(installation),
      windowLabel: hit.window.label,
      resetsAt: resetsAt.toUtc(),
      fireAt: resetsAt.add(kResumeResetMargin).toUtc(),
      message: message.trim(),
      permissionMode: permissionMode,
      notify: notify,
      latePolicy: latePolicy,
      state: ScheduledResumeState.pending,
      liveWhenScheduled: isLive(session.id),
      scheduledBy: scheduledBy,
      scheduledAt: at,
    );
    resumes.replaceFor(resume, now: at);
    onArmed?.call();
    _tell(hit, outcome, resume: resume);
  }

  void _tell(
    UsageLimitHit hit,
    UsageLimitOutcome outcome, {
    String? refusal,
    ScheduledResume? resume,
  }) => notice(
    UsageLimitNotice(
      sessionId: hit.sessionId,
      agentName: hit.agentName,
      windowLabel: hit.window.label,
      resetsAt: hit.window.resetsAt,
      outcome: outcome,
      refusal: refusal,
      resumeId: resume?.id,
      resumeFireAt: resume?.fireAt,
      resumeMessage: resume?.message,
    ),
  );
}
