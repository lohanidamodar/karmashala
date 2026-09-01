import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../agents/domain/agent_status.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_status_providers.dart';
import '../../sessions/application/session_ui_providers.dart';
import '../../sessions/domain/session_status.dart';
import '../domain/session_ending.dart';
import 'follow_up_providers.dart';

/// Turns "a session ended" into a call on [FollowUpService], from the two
/// signals the app actually has.
///
/// **The durable one is the row.** Every session-revision bump re-reads the
/// workspace and sweeps it, so an ending is noticed even if the app was not
/// running when it happened — which is the case that matters, because the
/// moment a session dies is precisely when nobody is looking. It is also what
/// makes the feature survive a restart with no in-memory state to rebuild.
///
/// **The live one is the status pipeline.** A pane-hosted session almost never
/// gets a terminal row status — `SessionEngine` writes one and no in-app
/// session uses it now that they all run in a PTY (Loop 41) — so a crash in the
/// ordinary case is visible only as the status settling on
/// [AgentActivityStatus.failed]. This listens for that, through
/// `agentSessionStatusProvider`, which is a read-only projection of the one
/// registry the whole app shares: no timer, no filesystem access, no poll of
/// its own. `SessionCheckpointRecorder` reaches the same signal the same way,
/// and this deliberately copies it rather than inventing a second seam.
///
/// [endingOfTransition] is what keeps that second signal honest — a first
/// observation is not a change, and a turn ending is not a session ending.
///
/// **It has to be watched, not read.** Riverpod 3 *pauses* a provider's own
/// subscriptions while nothing is listening to that provider, so an observer
/// nobody watches sees no status changes at all — silently, which is the worst
/// possible failure for a thing whose whole job is noticing. `openFollowUps`
/// watches it, and the attention inbox watches that, so the chain is live for
/// as long as the window's status bar is.
class SessionEndingObserver extends Notifier<int> {
  @override
  int build() {
    // Re-read whenever the workspace changes, so a session started after this
    // was built is watched too.
    ref.watch(sessionsRevisionProvider);

    final sessions = ref.read(sessionDaoProvider).getAll();
    final service = ref.read(followUpServiceProvider);
    service.sweep(sessions);

    for (final session in sessions) {
      // Only sessions the row still believes are live. An ended one has already
      // been judged by the sweep above, from a signal that does not evaporate.
      if (session.status != SessionStatus.running) continue;
      ref.listen(agentSessionStatusProvider(session.id), (previous, next) {
        final to = next.value?.status;
        if (to == null) return;
        final ending = endingOfTransition(
          from: previous?.value?.status,
          to: to,
        );
        if (ending == null) return;
        service.notice(sessionId: session.id, ending: ending);
      });
    }
    return sessions.length;
  }
}
