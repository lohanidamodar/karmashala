import 'package:riverpod/riverpod.dart';

import 'package:agent_cli/descriptors.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_status_providers.dart';
import '../../sessions/application/session_signals.dart';
import 'package:karmashala_session/session.dart';
import '../../terminal/application/pane_exit_signal.dart';
import '../domain/session_ending.dart';
import 'follow_up_providers.dart';

/// Turns "a session ended" into a call on [FollowUpService], from three
/// signals: the row, the [AgentActivityStatus] pipeline, and a pane's own exit.
/// **It has to be watched**: Riverpod 3 pauses an unwatched provider silently.
class SessionEndingObserver extends Notifier<int> {
  /// How many times this has seen the follow-up list change. On the notifier
  /// rather than in [state], because [build] re-runs on every workspace change.
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

    // **The clean finish**, which neither other signal carries. One subscription
    // for the whole app; the session it names is looked up when it arrives.
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
