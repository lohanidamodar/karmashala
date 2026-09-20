import 'dart:async';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/usage.dart';
import 'package:flutter/foundation.dart';
import 'package:karmashala_session/session.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/util/clock_provider.dart';
import '../../agents/application/agent_providers.dart';
import '../../agents/application/agent_usage_providers.dart';
import '../../agents/presentation/usage_chip.dart' show formatResetClock;
import '../../environments/application/environment_providers.dart';
import '../../notifications/application/attention_inbox.dart';
import '../../notifications/application/notification_providers.dart';
import '../../notifications/application/session_status_registry.dart';
import 'package:karmashala_notifications/attention.dart';
import '../../sessions/application/session_notice.dart';
import '../../sessions/application/session_providers.dart';
import '../../settings/application/settings_controller.dart';
import '../../settings/domain/usage_limit_settings.dart';
import 'package:karmashala_automations/resumes.dart';
import 'scheduled_resume_providers.dart';

/// Claude Code's own word, in `StopFailure.error`, for a turn a limit ended.
const String kClaudeRateLimitReason = 'rate_limit';

/// How old a Codex rate-limit record may be and still explain *this* turn
/// ending. Older, and it is the last thing a previous run knew.
const Duration kLimitRecordFreshness = Duration(minutes: 10);

/// A request for the resume dialog, from code that holds no `BuildContext`.
@immutable
class ResumeDialogRequest {
  const ResumeDialogRequest(this.sessionIds, this.serial, {this.namedWindow});

  final List<String> sessionIds;

  /// Distinguishes two requests for the same sessions.
  final int serial;

  /// The window the agent's own limit record named, to preselect.
  final String? namedWindow;
}

class ResumeDialogRequests extends Notifier<ResumeDialogRequest?> {
  int _serial = 0;

  @override
  ResumeDialogRequest? build() => null;

  void open(List<String> sessionIds, {String? namedWindow}) {
    if (sessionIds.isEmpty) return;
    state = ResumeDialogRequest(
      List.unmodifiable(sessionIds),
      ++_serial,
      namedWindow: namedWindow,
    );
  }
}

final resumeDialogRequestProvider =
    NotifierProvider<ResumeDialogRequests, ResumeDialogRequest?>(
      ResumeDialogRequests.new,
    );

/// Every status move, from any source. A seam, so a test emits one.
final sessionStatusChangesProvider = Provider<Stream<SessionStatusEntry>>(
  (ref) => ref.watch(sessionStatusRegistryProvider).statusChanges,
);

/// Reads a Codex rollout's newest rate-limit block. A seam over the file read.
final codexRateLimitReaderProvider =
    Provider<Future<CodexRateLimitSnapshot?> Function(String path)>(
      (ref) => readCodexRateLimits,
    );

/// One session's turn ending on its account's usage limit.
@immutable
class UsageLimitHit {
  const UsageLimitHit({
    required this.sessionId,
    required this.agentName,
    required this.window,
  });

  final String sessionId;
  final String agentName;

  /// The window refusing work. Its reset is what a resume would wait for.
  final UsageWindow window;

  /// "Codex hit its 5-hour limit. Resets 14:05."
  String sentence(DateTime now) {
    final resets = window.resetsAt;
    return '$agentName hit its ${window.label} limit.'
        '${resets == null ? '' : ' Resets ${formatResetClock(resets, now)}.'}';
  }
}

/// Notices a turn that ended on a usage limit and, as the setting says, offers
/// a resume at the reset or arms one. Must be watched (Riverpod 3).
class UsageLimitWatcher extends Notifier<int> {
  /// The reset last acted on per session, so one limit is one offer however
  /// many status moves follow it.
  final Map<String, DateTime> _handled = {};
  bool _disposed = false;

  @override
  int build() {
    _disposed = false;
    final changes = ref.watch(sessionStatusChangesProvider).listen((entry) {
      if (entry.session.imported) return;
      final status = entry.report.status;
      if (status != AgentActivityStatus.idle &&
          status != AgentActivityStatus.failed) {
        return;
      }
      // The stream is synchronous and may fire mid-build; nothing here is.
      unawaited(Future<void>.microtask(() => consider(entry)));
    });
    ref.onDispose(() {
      _disposed = true;
      changes.cancel();
    });
    return 0;
  }

  DateTime get _now => ref.read(clockProvider).nowUtc();

  /// What [entry] says about a limit, acted on once per reset.
  Future<void> consider(SessionStatusEntry entry) async {
    if (_disposed) return;
    final behavior = ref.read(settingsControllerProvider).usageLimitBehavior;
    if (behavior == UsageLimitBehavior.nothing) return;
    final session = ref.read(sessionDaoProvider).getById(entry.session.openId);
    if (session == null || session.isArchived) return;

    final hit = await detect(session, entry);
    if (hit == null || _disposed) return;
    final resets = hit.window.resetsAt;
    if (resets == null || !resets.isAfter(_now)) return;
    final handled = _handled[session.id];
    if (handled != null &&
        handled.difference(resets).abs() <= kResumeSameReset) {
      return;
    }
    _handled[session.id] = resets;
    // Already waiting on a resume: the limit is not news to its owner.
    if (ref.read(scheduledResumeDaoProvider).liveFor(session.id) != null) {
      return;
    }

    _file(entry, hit);
    if (behavior == UsageLimitBehavior.schedule) {
      _scheduleUnasked(hit);
      return;
    }
    // Asked once for this session, and it worked: the limit coming back is the
    // case that arrangement was made for, so it is made again rather than
    // re-offered. Cancelling the row is what ends the chain.
    final standing = _standingArrangement(hit.sessionId);
    if (standing != null) {
      _renew(hit, standing);
      return;
    }
    _offer(hit);
  }

  /// The resume this session should keep renewing, or null.
  ///
  /// Only a resume that waited on a usage **window** and reached it: a time
  /// the user picked is one moment, not an arrangement, and a cancelled or
  /// failed row is not something to repeat unasked.
  ScheduledResume? _standingArrangement(String sessionId) {
    final last = ref.read(scheduledResumeDaoProvider).lastEndedFor(sessionId);
    if (last == null || last.state != ScheduledResumeState.done) return null;
    return last.windowLabel == null ? null : last;
  }

  /// Arms [previous] again for this limit, with everything the user chose the
  /// first time — the message, the mode, whether to notify, and who armed it.
  void _renew(UsageLimitHit hit, ScheduledResume previous) {
    final ScheduledResume resume;
    try {
      resume = ref
          .read(scheduledResumeControllerProvider)
          .schedule(
            ResumeRequest.atReset(
              sessionId: hit.sessionId,
              window: hit.window,
              message: previous.message,
              permissionMode: previous.permissionMode,
              notify: previous.notify,
              latePolicy: previous.latePolicy,
              scheduledBy: previous.scheduledBy,
            ),
          );
    } on ScheduledResumeRefused catch (refused) {
      _offer(hit, refusal: refused.reason);
      return;
    }
    _say(hit, resume, renewed: true);
  }

  /// The limit behind [entry], or null. Per agent, and only from evidence the
  /// agent itself wrote: a hook's failure reason, or a rollout's own record.
  Future<UsageLimitHit?> detect(
    Session session,
    SessionStatusEntry entry,
  ) async {
    final installation = ref
        .read(agentInstallationDaoProvider)
        .getById(session.agentInstallationId);
    if (installation == null) return null;
    final name = ref
        .read(agentRegistryProvider)
        .displayNameFor(installation.agentId);
    final now = _now;

    switch (installation.agentId) {
      case AgentIds.claudeCode:
        if (entry.report.failureReason != kClaudeRateLimitReason) return null;
        // `rate_limit` is also a passing 429. Only a spent window makes it a
        // usage limit, and only a reading names the reset.
        final access = resumeUsageAccess(ref, session);
        if (!access.readable) return null;
        final AgentUsage reading;
        try {
          reading = await ref
              .read(agentUsageServiceProvider)
              .fetch(
                installation,
                ref.read(executionEnvironmentDaoProvider).getAll(),
              );
        } on UsageException {
          return null;
        }
        final blocking = blockingWindow(reading.windows, now: now);
        if (blocking == null || blocking.reason != BlockingWindowReason.spent) {
          return null;
        }
        return UsageLimitHit(
          sessionId: session.id,
          agentName: name,
          window: blocking.window,
        );
      case AgentIds.codex:
        final path = entry.session.stateFilePath;
        if (path == null || path.isEmpty) return null;
        final snapshot = await ref.read(codexRateLimitReaderProvider)(path);
        if (snapshot == null || !snapshot.limitReached) return null;
        final recordedAt = snapshot.recordedAt;
        if (recordedAt == null ||
            now.difference(recordedAt) > kLimitRecordFreshness) {
          return null;
        }
        final window =
            snapshot.blocking ??
            blockingWindow(snapshot.windows, now: now)?.window;
        if (window == null) return null;
        return UsageLimitHit(
          sessionId: session.id,
          agentName: name,
          window: window,
        );
      default:
        return null;
    }
  }

  void _file(SessionStatusEntry entry, UsageLimitHit hit) {
    ref
        .read(attentionInboxProvider.notifier)
        .raise(
          InboxItem(
            session: entry.session,
            kind: InboxItemKind.usageLimit,
            at: _now,
            detail: hit.sentence(_now.toLocal()),
          ),
        );
  }

  void _offer(UsageLimitHit hit, {String? refusal}) {
    final requests = ref.read(resumeDialogRequestProvider.notifier);
    void options() =>
        requests.open([hit.sessionId], namedWindow: hit.window.label);
    ref
        .read(sessionNoticesProvider.notifier)
        .post(
          hit.sessionId,
          SessionNotice(
            message: refusal == null
                ? hit.sentence(_now.toLocal())
                : '${hit.sentence(_now.toLocal())} A resume was not '
                      'scheduled: $refusal',
            tone: SessionNoticeTone.warning,
            sticky: true,
            action: refusal != null
                ? SessionNoticeAction(label: 'Options…', onPressed: options)
                : SessionNoticeAction(
                    label: 'Resume then',
                    onPressed: () => _resumeThen(hit),
                  ),
            secondaryAction: refusal != null
                ? null
                : SessionNoticeAction(label: 'Options…', onPressed: options),
          ),
        );
  }

  /// One click: the defaults, at this window's reset. A refusal comes back as
  /// the same notice with the gate's sentence and the way into the options.
  void _resumeThen(UsageLimitHit hit) {
    final resume = _schedule(hit, scheduledBy: 'the user');
    if (resume == null) return;
    _say(hit, resume);
  }

  void _scheduleUnasked(UsageLimitHit hit) {
    final resume = _schedule(hit, scheduledBy: kResumeScheduledBySetting);
    if (resume != null) _say(hit, resume);
  }

  ScheduledResume? _schedule(UsageLimitHit hit, {required String scheduledBy}) {
    final session = ref.read(sessionDaoProvider).getById(hit.sessionId);
    final agentId = session == null
        ? null
        : ref
              .read(agentInstallationDaoProvider)
              .getById(session.agentInstallationId)
              ?.agentId;
    final settings = ref.read(settingsControllerProvider);
    try {
      return ref
          .read(scheduledResumeControllerProvider)
          .schedule(
            ResumeRequest.atReset(
              sessionId: hit.sessionId,
              window: hit.window,
              message: agentId == null
                  ? settings.resumeMessage
                  : settings.resumeMessageFor(agentId),
              scheduledBy: scheduledBy,
            ),
          );
    } on ScheduledResumeRefused catch (refused) {
      _offer(hit, refusal: refused.reason);
      return null;
    }
  }

  void _say(UsageLimitHit hit, ScheduledResume resume, {bool renewed = false}) {
    final now = _now.toLocal();
    final requests = ref.read(resumeDialogRequestProvider.notifier);
    ref
        .read(sessionNoticesProvider.notifier)
        .post(
          hit.sessionId,
          SessionNotice(
            message:
                '${hit.sentence(now)} Resumes '
                '${formatResetClock(resume.fireAt, now)}'
                '${resume.sendsMessage ? ' and sends '
                          '"${resume.message}"' : ''}.'
                // Said, because nobody clicked anything this time.
                '${renewed ? ' You had this session resuming at the reset, so '
                          'it was set up again — Cancel stops it coming '
                          'back.' : ''}',
            action: SessionNoticeAction(
              label: 'Change…',
              onPressed: () => requests.open([hit.sessionId]),
            ),
            secondaryAction: SessionNoticeAction(
              label: 'Cancel',
              onPressed: () => ref
                  .read(scheduledResumeControllerProvider)
                  .cancelFor(hit.sessionId),
            ),
          ),
        );
  }
}

final usageLimitWatcherProvider = NotifierProvider<UsageLimitWatcher, int>(
  UsageLimitWatcher.new,
);
