import 'package:riverpod/riverpod.dart';

import '../../agents/domain/agent_status.dart';
import '../data/session_dao.dart';
import '../domain/session_status.dart';
import 'session_providers.dart';
import 'session_signals.dart';

/// **Writes a session row's ending from what the agent said, and from nothing
/// else.**
///
/// Until this existed the only transition a pane-hosted row ever made was
/// *into* `running`: `SessionLauncher` wrote it, `SessionLivenessReconciler`
/// could take it back out to [SessionStatus.unknown], and the six terminal
/// words were written by `SessionEngine`, which no in-app session uses. So a
/// conversation that finished cleanly went on saying `running`.
///
/// ## Why not the pane's exit code
///
/// Because exit **0** is not a statement about the agent. `endingOfPaneExit`
/// reads it and nothing else, and its own documentation says why: a Ctrl-C, a
/// `wsl.exe` wrapper that fell over before the CLI started and a finished
/// conversation are indistinguishable from the number. Turning it into a row
/// status would put a word on every one of them, permanently, and a wrong
/// ending survives a restart in a way a wrong badge does not.
///
/// A hook is the opposite kind of evidence: the agent fired it, about itself,
/// naming the event. See [AgentSessionEnding] and `AgentHookSpec.eventEnding`
/// for which events each CLI has, and `agent_hook_intake.dart` for where this
/// is called — one place, so both hook transports agree.
///
/// ## Three refusals
///
/// * **No ending, no write.** Every tool event, and `Stop` on all three CLIs,
///   ends a turn and not a session. The row keeps what it had.
/// * **A terminal word is never overwritten.** `cancelled` is what the user's
///   own stop wrote, and Claude Code fires `SessionEnd` on the way out
///   afterwards; taking `completed` from that would erase the user's action.
///   The same guard keeps a `failed` from `StopFailure` from being smoothed
///   into `completed` by the exit that follows it.
/// * **A conversation we have no row for is not ours.** A hook can name a
///   session started outside the workspace entirely.
class SessionOutcomeWriter {
  SessionOutcomeWriter({required this.sessionDao, this.onChanged});

  final SessionDao sessionDao;

  /// Called with each row this moved, so the workspace can redraw.
  final void Function(String sessionId)? onChanged;

  /// Rows given an ending. Diagnostics, and what the tests count.
  int written = 0;

  /// Applies [ending] to the row recording CLI conversation [agentSessionId].
  ///
  /// Returns the row id it wrote, or null when it wrote nothing — which is the
  /// common case and not a failure.
  String? record({
    required String agentSessionId,
    required AgentSessionEnding? ending,
  }) {
    if (ending == null || agentSessionId.isEmpty) return null;
    final session = sessionDao.getByExternalSessionId(agentSessionId);
    if (session == null) return null;
    // Already ended, by this or by the user. See the second refusal above.
    if (session.status.isEnded) return null;
    final status = switch (ending) {
      AgentSessionEnding.completed => SessionStatus.completed,
      AgentSessionEnding.failed => SessionStatus.failed,
    };
    if (session.status == status) return null;
    sessionDao.updateStatus(session.id, status);
    written++;
    onChanged?.call(session.id);
    return session.id;
  }
}

final sessionOutcomeWriterProvider = Provider<SessionOutcomeWriter>(
  (ref) => SessionOutcomeWriter(
    sessionDao: ref.watch(sessionDaoProvider),
    onChanged: (sessionId) => ref
        .read(sessionsRevisionProvider.notifier)
        .changed(SessionChange.statusChanged(sessionId)),
  ),
);
