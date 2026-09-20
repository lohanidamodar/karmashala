import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_core/logging.dart';

import '../../explorer/application/explorer_actions.dart';
import 'quit_resume.dart';
import 'session_notice.dart';

final _log = AppLogger.named('sessions.quit');

/// Reopens whatever the last quit was asked to bring back.
///
/// Goes through [ExplorerActions.openNative] — the same call a click on the
/// row makes — rather than a second launch path, so every refusal a manual
/// reopen would hit is hit here too and said in the same words. Nothing is
/// typed into any of them: the offer was to have the sessions open, and
/// finishing the turn that was interrupted is not something the app can do.
Future<void> reopenSessionsFromLastQuit(
  WidgetRef ref, {
  @visibleForTesting QuitResumePlan? plan,
}) async {
  final decided = plan ?? ref.read(quitResumeServiceProvider).planForLaunch();
  if (decided.isEmpty) return;

  for (final skip in decided.skipped) {
    // Said on the session itself: a user who ticked the box is owed the reason
    // this particular one is not back, not a count of how many were not.
    _log.info('quit: not reopening ${skip.sessionId} — ${skip.reason}.');
    ref
        .read(sessionNoticesProvider.notifier)
        .post(
          skip.sessionId,
          SessionNotice(
            message:
                'This was not reopened after the last quit because '
                '${skip.reason}.',
            tone: SessionNoticeTone.warning,
          ),
        );
  }

  final actions = ref.read(explorerActionsProvider);
  for (final id in decided.resume) {
    try {
      final result = await actions.openNative(id);
      final message = result.message;
      if (message == null) continue;
      ref
          .read(sessionNoticesProvider.notifier)
          .post(id, SessionNotice(message: message));
    } on Object catch (error, stack) {
      // One that will not come back must not stop the rest coming back.
      _log.warning('quit: reopening $id failed.', error, stack);
      ref
          .read(sessionNoticesProvider.notifier)
          .post(
            id,
            SessionNotice(
              message: 'This could not be reopened after the last quit: $error',
              tone: SessionNoticeTone.warning,
            ),
          );
    }
  }
}
