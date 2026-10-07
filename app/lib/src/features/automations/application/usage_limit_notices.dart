import 'package:flutter/foundation.dart';
import 'package:karmashala_automations/resumes.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/data/data_providers.dart';
import '../../../core/util/clock_provider.dart';
import '../../agents/application/agent_providers.dart';
import '../../agents/presentation/usage_chip.dart' show formatResetClock;
import '../../sessions/application/session_notice.dart';
import '../../sessions/application/session_providers.dart';
import '../../settings/application/settings_controller.dart';
import 'scheduled_resume_providers.dart';

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

/// "Codex hit its 5-hour limit. Resets 14:05." — worded here, at [now]'s
/// local clock, since only the client knows the person's time zone.
String usageLimitSentence(UsageLimitNotice notice, DateTime now) {
  final resets = notice.resetsAt;
  return '${notice.agentName} hit its ${notice.windowLabel} limit.'
      '${resets == null ? '' : ' Resets ${formatResetClock(resets, now)}.'}';
}

/// **The notice for a usage limit the server noticed** (slice 5c): the
/// server detects the limit, files it in the inbox and — as Settings says —
/// offers, arms or re-arms a resume at the reset; this says so in the
/// session's own bar, with the actions a person takes from there. Nothing
/// here detects, schedules unasked or files. Must be watched (Riverpod 3).
class UsageLimitNotices extends Notifier<int> {
  @override
  int build() {
    final changes = ref.watch(dataClientProvider).attentionChanges.listen((
      change,
    ) {
      if (change is UsageLimitNoticed) present(change.notice);
    });
    ref.onDispose(changes.cancel);
    return 0;
  }

  DateTime get _now => ref.read(clockProvider).nowUtc();

  /// Posts [notice]'s bar, by what the server did.
  void present(UsageLimitNotice notice) {
    switch (notice.outcome) {
      case UsageLimitOutcome.offered:
        _offer(notice);
      case UsageLimitOutcome.refused:
        _offer(
          notice,
          refusal: notice.refusal ?? 'it could not run unattended',
        );
      case UsageLimitOutcome.scheduled || UsageLimitOutcome.renewed:
        final fireAt = notice.resumeFireAt;
        if (fireAt == null) return;
        _say(
          notice,
          fireAt: fireAt,
          message: notice.resumeMessage ?? '',
          renewed: notice.outcome == UsageLimitOutcome.renewed,
        );
    }
  }

  void _offer(UsageLimitNotice notice, {String? refusal}) {
    final requests = ref.read(resumeDialogRequestProvider.notifier);
    void options() =>
        requests.open([notice.sessionId], namedWindow: notice.windowLabel);
    final sentence = usageLimitSentence(notice, _now.toLocal());
    ref
        .read(sessionNoticesProvider.notifier)
        .post(
          notice.sessionId,
          SessionNotice(
            message: refusal == null
                ? sentence
                : '$sentence A resume was not scheduled: $refusal',
            tone: SessionNoticeTone.warning,
            sticky: true,
            action: refusal != null
                ? SessionNoticeAction(label: 'Options…', onPressed: options)
                : SessionNoticeAction(
                    label: 'Resume then',
                    onPressed: () => resumeThen(notice),
                  ),
            secondaryAction: refusal != null
                ? null
                : SessionNoticeAction(label: 'Options…', onPressed: options),
          ),
        );
  }

  /// One click: the defaults, at this window's reset, armed through the
  /// server. A refusal comes back as the same bar with the gate's sentence.
  void resumeThen(UsageLimitNotice notice) {
    final resetsAt = notice.resetsAt;
    if (resetsAt == null) return;
    final session = ref.read(sessionsDataProvider).getById(notice.sessionId);
    final agentId = session == null
        ? null
        : ref
              .read(agentInstallationsDataProvider)
              .getById(session.agentInstallationId)
              ?.agentId;
    final settings = ref.read(settingsControllerProvider);
    final ScheduledResume resume;
    try {
      resume = ref
          .read(scheduledResumeControllerProvider)
          .schedule(
            ResumeRequest(
              sessionId: notice.sessionId,
              fireAt: resetsAt.add(kResumeResetMargin),
              windowLabel: notice.windowLabel,
              resetsAt: resetsAt,
              message: agentId == null
                  ? settings.resumeMessage
                  : settings.resumeMessageFor(agentId),
            ),
          );
    } on ScheduledResumeRefused catch (refused) {
      _offer(notice, refusal: refused.reason);
      return;
    }
    _say(notice, fireAt: resume.fireAt, message: resume.message);
  }

  void _say(
    UsageLimitNotice notice, {
    required DateTime fireAt,
    required String message,
    bool renewed = false,
  }) {
    final now = _now.toLocal();
    final requests = ref.read(resumeDialogRequestProvider.notifier);
    final sends = message.trim().isNotEmpty;
    ref
        .read(sessionNoticesProvider.notifier)
        .post(
          notice.sessionId,
          SessionNotice(
            message:
                '${usageLimitSentence(notice, now)} Resumes '
                '${formatResetClock(fireAt, now)}'
                '${sends ? ' and sends "$message"' : ''}.'
                // Said, because nobody clicked anything this time.
                '${renewed ? ' You had this session resuming at the reset, so '
                          'it was set up again — Cancel stops it coming '
                          'back.' : ''}',
            action: SessionNoticeAction(
              label: 'Change…',
              onPressed: () => requests.open([notice.sessionId]),
            ),
            secondaryAction: SessionNoticeAction(
              label: 'Cancel',
              onPressed: () => ref
                  .read(scheduledResumeControllerProvider)
                  .cancelFor(notice.sessionId),
            ),
          ),
        );
  }
}

final usageLimitNoticesProvider = NotifierProvider<UsageLimitNotices, int>(
  UsageLimitNotices.new,
);
