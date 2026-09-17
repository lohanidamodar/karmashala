import 'dart:async';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/usage.dart';
import 'package:karmashala_session/launch.dart';
import 'package:karmashala_session/session.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/util/clock_provider.dart';
import '../../agents/application/agent_providers.dart';
import '../../agents/application/agent_usage_providers.dart';
import '../../agents/presentation/usage_chip.dart' show formatResetClock;
import '../../environments/application/environment_providers.dart';
import '../../notifications/application/notification_providers.dart';
import '../../notifications/domain/notification_request.dart';
import '../../repositories/application/repository_providers.dart';
import '../../sessions/application/decision_recorder.dart';
import '../../sessions/application/session_launcher.dart';
import '../../sessions/application/session_notice.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_status_providers.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import '../domain/resume_window.dart';
import '../domain/scheduled_resume.dart';
import 'automation_scheduler.dart';
import 'scheduled_resume_providers.dart';
import 'unattended_preflight.dart';

/// What happens when a scheduled resume comes due. Every call must leave the
/// row out of `pending`, or the same fire would repeat on every tick.
abstract interface class ScheduledResumeFiring {
  Future<void> fire(ScheduledResume resume, {String note});
}

final scheduledResumeFiringProvider = Provider<ScheduledResumeFiring>(
  ScheduledResumeRunner.new,
);

/// Firing one resume: the gate again, the account's usage again, then the
/// session's own resume path and one message once the agent is at its input.
class ScheduledResumeRunner implements ScheduledResumeFiring {
  const ScheduledResumeRunner(this._ref);

  final Ref _ref;

  ScheduledResumeController get _controller =>
      _ref.read(scheduledResumeControllerProvider);
  DateTime get _now => _ref.read(clockProvider).nowUtc();

  @override
  Future<void> fire(ScheduledResume resume, {String note = ''}) async {
    // Claimed in the store, so two ticks cannot both resume one session.
    final claimed = _ref
        .read(scheduledResumeDaoProvider)
        .transition(
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
    final session = _ref.read(sessionDaoProvider).getById(resume.sessionId);
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

    final launcher = _ref.read(sessionLauncherProvider);
    final live = launcher.livePaneFor(session.id) != null;
    if (live && !resume.liveWhenScheduled) {
      _finish(
        resume,
        ScheduledResumeState.cancelled,
        'You resumed this session yourself before its time, so the scheduled '
        'resume was cancelled and nothing was sent.',
      );
      return;
    }

    final refusal = _ref
        .read(unattendedPreflightProvider)
        .refusalForResume(session, permissionMode: resume.permissionMode);
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
      await _resumeAndSend(resume, session, [note, usageNote]);
    }
  }

  /// Re-reads the account. Returns a note to carry when the resume may go
  /// ahead, or null when the row was rescheduled or ended here.
  Future<String?> _checkUsage(ScheduledResume resume, Session session) async {
    final access = resumeUsageAccess(_ref, session);
    final installation = access.installation;
    if (!access.readable || installation == null) {
      return 'Usage could not be re-read here, so this went by the time alone.';
    }
    final service = _ref.read(agentUsageServiceProvider);
    AgentUsage reading;
    try {
      // Through the throttle: inside the ask floor this is the remembered
      // reading, and no request is made faster than the refresh policy allows.
      reading = await service.fetch(
        installation,
        _ref.read(executionEnvironmentDaoProvider).getAll(),
      );
    } on UsageException catch (error) {
      return 'Usage could not be re-read (${error.message}), so this went by '
          'the reset time the provider gave.';
    }

    final now = _now;
    final switched =
        access.accountKey != resume.accountKey ||
        (resume.accountEmail != null &&
            reading.email != null &&
            reading.email != resume.accountEmail);
    final switchedNote = switched
        ? 'The account this session uses changed since this was scheduled, so '
              'the new one was checked. '
        : '';

    switch (checkReset(reading, now: now)) {
      case ResetConfirmed():
        return switched ? switchedNote.trim() : '';
      case ReadingPredatesReset():
        final attempts = resume.attempts + 1;
        if (attempts >= kResumeMaxAttempts) {
          _giveUp(resume, attempts, 'no reading newer than the reset arrived');
          return null;
        }
        final wait = service.dueIn(installation) + kUsageResetGrace;
        final again = now.add(
          wait < const Duration(seconds: 30)
              ? const Duration(seconds: 30)
              : wait,
        );
        _controller.reschedule(
          resume,
          fireAt: again,
          resetsAt: resume.resetsAt,
          attempts: attempts,
          accountKey: access.accountKey,
          accountEmail: reading.email,
          reason:
              '${switchedNote}The last usage reading predates the reset. '
              'Looking again at ${formatResetClock(again, now.toLocal())}.',
        );
        return null;
      case StillLimited(:final label, :final until):
        final attempts = resume.attempts + 1;
        final again = nextResumeAttempt(
          attempts: attempts,
          now: now,
          until: until,
        );
        if (again == null) {
          _giveUp(resume, attempts, 'the $label window is still at its limit');
          return null;
        }
        _controller.reschedule(
          resume,
          fireAt: again,
          resetsAt: until,
          attempts: attempts,
          accountKey: access.accountKey,
          accountEmail: reading.email,
          reason:
              '${switchedNote}Still limited: the $label window '
              '${until == null ? 'names no reset yet' : 'resets '
                        '${formatResetClock(until, now.toLocal())}'}. '
              'Trying again at ${formatResetClock(again, now.toLocal())}.',
        );
        return null;
    }
  }

  void _giveUp(ScheduledResume resume, int attempts, String why) {
    _finish(
      resume.copyWith(attempts: attempts),
      ScheduledResumeState.failed,
      'Gave up after $attempts checks: $why. Nothing was resumed or sent — '
      'schedule it again once the limit is back.',
    );
  }

  /// Whether the open session runs under another mode than the one this
  /// resume was armed with — the mode the gate passed is the one it must run in.
  bool _needsRestart(Session session, ScheduledResume resume) {
    final chosen = resume.permissionMode;
    if (chosen == null) return false;
    final launcher = _ref.read(sessionLauncherProvider);
    final running = launcher.effectivePermissionFor(session.id);
    final agentId = running?.descriptor?.id;
    if (running == null || agentId == null) return false;
    final wanted = launcher.permissionFor(
      agentId,
      SessionPurpose.existingSession,
      sessionMode: chosen,
    );
    return wanted.canonical != running.selection.canonical;
  }

  Future<void> _sendToLive(
    ScheduledResume resume,
    Session session,
    List<String> notes,
  ) async {
    final report = _ref.read(sessionStatusLookupProvider)(session.id);
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
    if (report != null && report.hasOpenPrompt) {
      _finish(
        resume,
        ScheduledResumeState.failed,
        'The agent has a prompt open, and a message typed there would answer '
        'it. Nothing was sent.',
      );
      return;
    }
    _send(resume, session, notes, opened: false);
  }

  Future<void> _resumeAndSend(
    ScheduledResume resume,
    Session session,
    List<String> notes,
  ) async {
    final repository = _ref
        .read(repositoryDaoProvider)
        .getById(session.repositoryId);
    var installation = _ref
        .read(agentInstallationDaoProvider)
        .getById(session.agentInstallationId);
    final externalId = session.externalSessionId;
    if (repository == null || installation == null) {
      _finish(
        resume,
        ScheduledResumeState.failed,
        'The checkout or the agent went away between the gate and the resume.',
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

    final launcher = _ref.read(sessionLauncherProvider);
    final livePane = launcher.livePaneFor(session.id);
    if (livePane != null) {
      final report = _ref.read(sessionStatusLookupProvider)(session.id);
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

    // The message rides the command line where the agent takes one there: the
    // CLI submits it when it is ready, and nothing is typed at a starting TUI.
    final message = resume.message.trim();
    final asArgument =
        message.isNotEmpty &&
        (_ref
                .read(agentRegistryProvider)
                .byId(installation.agentId)
                ?.launch
                .acceptsPromptArgument ??
            false);

    try {
      if (livePane != null) {
        // Open under another mode than the one armed. Every refusal comes
        // before the kill, which cannot be undone.
        installation = await launcher.usableInstallation(installation);
        launcher.setPermissionMode(
          session.id,
          PermissionSelection.parse(resume.permissionMode),
        );
        _ref
            .read(terminalSessionsControllerProvider.notifier)
            .endSession(livePane);
      }
      await launcher.launch(
        SessionLaunchRequest(
          repository: repository,
          installation: installation,
          title: session.title,
          purpose: SessionPurpose.existingSession,
          resumeExternalSessionId: externalId,
          existingWorktree: session.worktree,
          surface: session.surface,
          firstMessage: asArgument ? message : null,
          permissionOverride: PermissionSelection.parse(resume.permissionMode),
        ),
      );
    } on Object catch (error) {
      _finish(
        resume,
        ScheduledResumeState.failed,
        'The session could not be resumed: $error',
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
          // Typing at a TUI that is still starting is how a message gets lost
          // or answers a prompt, so it is not tried.
          : _join([
              'Resumed. This agent takes no opening message on its command '
                  'line, so "$message" was not sent — say it in the session.',
              ...notes,
            ]),
      sent: asArgument ? message : null,
    );
  }

  void _send(
    ScheduledResume resume,
    Session session,
    List<String> notes, {
    required bool opened,
  }) {
    final message = resume.message.trim();
    final sent = _ref.read(sessionLauncherProvider).sendTo(session.id, message);
    if (!sent) {
      _finish(
        resume,
        ScheduledResumeState.failed,
        'The session had no live pane to type into, so nothing was sent.',
      );
      return;
    }
    _finish(
      resume,
      ScheduledResumeState.done,
      _join([
        '${opened ? 'Resumed' : 'The session was already open'}, and sent '
            '"$message".',
        ...notes,
      ]),
      sent: message,
    );
  }

  void _finish(
    ScheduledResume resume,
    ScheduledResumeState state,
    String reason, {
    String? sent,
  }) {
    final ended = _controller.end(resume, state, reason);
    final session = _ref.read(sessionDaoProvider).getById(resume.sessionId);
    if (state == ScheduledResumeState.done) {
      final now = _now.toLocal();
      _ref
          .read(decisionRecorderProvider)
          .recordScheduledResume(
            sessionId: resume.sessionId,
            resumeId: resume.id,
            scheduledBy: resume.scheduledBy,
            summary: sent == null
                ? 'Resumed on schedule, with nothing sent'
                : 'Resumed on schedule and sent "$sent"',
            detail:
                'Scheduled by ${resume.scheduledBy} at '
                '${formatResetClock(resume.scheduledAt, now)} for '
                '${resume.windowLabel == null ? 'a chosen time' : 'the '
                          '${resume.windowLabel} reset'}.',
          );
    }
    _ref.read(resumeAnnouncerProvider).announce(ended, session);
    final repositoryId = session?.repositoryId;
    if (repositoryId != null && state != ScheduledResumeState.pending) {
      unawaited(
        _ref.read(automationSchedulerProvider.notifier).drain(repositoryId),
      );
    }
  }

  static String _join(List<String> parts) =>
      parts.where((part) => part.trim().isNotEmpty).join(' ');
}

/// Tells the user how a resume ended: always in the session's own bar, and as
/// a desktop notification when they asked for one or it went wrong unseen.
class ResumeAnnouncer {
  const ResumeAnnouncer(this._ref);

  final Ref _ref;

  void announce(ScheduledResume ended, Session? session) {
    final quiet =
        ended.state == ScheduledResumeState.cancelled &&
        ended.reason == 'Cancelled by you.';
    if (quiet) return;
    final failed =
        ended.state == ScheduledResumeState.failed ||
        ended.state == ScheduledResumeState.missed;
    _ref
        .read(sessionNoticesProvider.notifier)
        .post(
          ended.sessionId,
          SessionNotice(
            message: 'Scheduled resume: ${ended.reason}',
            tone: failed
                ? SessionNoticeTone.warning
                : SessionNoticeTone.neutral,
          ),
        );
    // A miss or a failure is announced whether or not they ticked the box:
    // the rule is never to run late, or not at all, in silence.
    if (!ended.notify && !failed) return;
    if (!_ref.read(notificationSettingsControllerProvider).enabled) return;
    unawaited(
      _ref
          .read(notificationPresenterProvider)
          .show(
            NotificationRequest(
              title: switch (ended.state) {
                ScheduledResumeState.done => 'Session resumed',
                ScheduledResumeState.missed => 'Scheduled resume missed',
                ScheduledResumeState.cancelled => 'Scheduled resume cancelled',
                _ => 'Scheduled resume failed',
              },
              body: '${session?.title ?? 'A session'} — ${ended.reason}',
              payload: NotificationPayload(
                openId: ended.sessionId,
                imported: false,
              ).encode(),
            ),
          ),
    );
  }
}

final resumeAnnouncerProvider = Provider<ResumeAnnouncer>(ResumeAnnouncer.new);
