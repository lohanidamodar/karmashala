import 'dart:async';

import 'package:karmashala_automations/resumes.dart';
import 'package:karmashala_notifications/toasts.dart';
import 'package:karmashala_session/session.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/data/data_providers.dart';
import '../../notifications/application/notification_providers.dart';
import '../../sessions/application/session_notice.dart';
import '../../sessions/application/session_providers.dart';

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

/// Whether [state] is how a resume ends.
bool isEndedResume(ScheduledResumeState state) => switch (state) {
  ScheduledResumeState.done ||
  ScheduledResumeState.cancelled ||
  ScheduledResumeState.missed ||
  ScheduledResumeState.failed => true,
  _ => false,
};

/// Announces each resume the **server** ended (slice 5c: it fires resumes
/// itself, with every window closed): a row this copy held live that the
/// server's word moved to an ending. Must be watched (Riverpod 3).
final serverResumeEndingsProvider = Provider<void>((ref) {
  final resumes = ref.watch(dataClientProvider).automations.resumes;
  final subscription = resumes.serverChanges.listen((change) {
    final before = change.before;
    final after = change.after;
    if (before == null || after == null) return;
    if (isEndedResume(before.state) || !isEndedResume(after.state)) return;
    ref
        .read(resumeAnnouncerProvider)
        .announce(
          after,
          ref.read(sessionsDataProvider).getById(after.sessionId),
        );
  });
  ref.onDispose(subscription.cancel);
});
