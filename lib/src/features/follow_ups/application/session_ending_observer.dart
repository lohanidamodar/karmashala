import 'package:riverpod/riverpod.dart';

import '../../agents/domain/agent_status.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_status_providers.dart';
import '../../sessions/application/session_signals.dart';
import '../../sessions/domain/session_status.dart';
import '../../terminal/application/pane_exit_signal.dart';
import '../domain/session_ending.dart';
import 'follow_up_providers.dart';

/// Turns "a session ended" into a call on [FollowUpService], from the three
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
/// **The third is the pane's own process stopping.** Neither of the other two
/// can say [SessionEnding.completed] for a pane-hosted session, so an agent
/// that simply *finished* — including one that walked away from a verification
/// run — ended in silence, which is the whole thing follow-ups are for.
/// `paneExitProvider` is a read-only fact published by the terminal, and
/// [endingOfPaneExit] is what keeps it honest: most pane exits are not a
/// session ending.
///
/// **It has to be watched, not read.** Riverpod 3 *pauses* a provider's own
/// subscriptions while nothing is listening to that provider, so an observer
/// nobody watches sees no status changes at all — silently, which is the worst
/// possible failure for a thing whose whole job is noticing. `openFollowUps`
/// watches it, and the attention inbox watches that, so the chain is live for
/// as long as the window's status bar is.
class SessionEndingObserver extends Notifier<int> {
  /// How many times this has seen the follow-up list change.
  ///
  /// The provider's value, and it lives on the notifier rather than in [state]
  /// because [build] re-runs on every workspace change and has to carry the
  /// count across. Readers use it as a revision: it stands still through a
  /// sweep that found nothing, which is nearly all of them, and a reader
  /// watching it therefore re-reads the table only when there is something new.
  int _revision = 0;

  @override
  int build() {
    // Re-read when a session appears, goes away or ends — a full table scan
    // and one `ref.listen` per running row, so it must not run for anything
    // else. A rename in particular says nothing this sweep can act on.
    ref.watchSessionKinds(const {
      SessionChangeKind.membership,
      SessionChangeKind.status,
    });

    final sessions = ref.read(sessionDaoProvider).getAll();
    final service = ref.read(followUpServiceProvider);
    if (service.sweep(sessions)) _revision++;

    // **The clean finish**, which neither of the other two signals carries: the
    // row never says `completed` for a pane-hosted session and the status
    // pipeline never settles on it. Not filtered by the session list above —
    // this is one subscription for the whole app, and the session it names is
    // looked up when it arrives rather than when this ran.
    ref.listen(paneExitProvider, (_, exit) {
      if (exit == null) return;
      // No session id is a plain shell tab, or an agent started outside the
      // session list: there is no row for a follow-up to be about.
      final sessionId = exit.sessionId;
      if (sessionId == null) return;
      final ending = endingOfPaneExit(exit.exitCode);
      if (ending == null) return;
      if (service.notice(sessionId: sessionId, ending: ending) != null) {
        state = ++_revision;
      }
    });

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
        if (service.notice(sessionId: session.id, ending: ending) != null) {
          state = ++_revision;
        }
      });
    }
    return _revision;
  }
}
