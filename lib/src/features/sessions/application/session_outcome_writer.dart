import 'package:riverpod/riverpod.dart';

import 'package:agent_cli/descriptors.dart';
import '../data/session_dao.dart';
import '../domain/session_status.dart';
import 'session_providers.dart';
import 'session_signals.dart';

/// **Writes a session row's ending from what the agent said, and from nothing
/// else.** Until this existed the only transition a pane-hosted row ever made
/// was *into* `running`, so a conversation that finished cleanly went on saying
/// `running`.
///
/// Not the pane's exit code: exit **0** cannot tell a Ctrl-C, a `wsl.exe`
/// wrapper that fell over before the CLI started and a finished conversation
/// apart, and a wrong ending survives a restart in a way a wrong badge does
/// not. A hook is the opposite kind of evidence — the agent fired it, about
/// itself, naming the event.
///
/// Three refusals: no ending, no write (every tool event, and `Stop` on all
/// three CLIs, ends a turn and not a session); a terminal word is never
/// overwritten, because `cancelled` is what the user's own stop wrote and
/// Claude Code fires `SessionEnd` afterwards; and a conversation we have no row
/// for is not ours.
class SessionOutcomeWriter {
  SessionOutcomeWriter({required this.sessionDao, this.onChanged});

  final SessionDao sessionDao;

  /// Called with each row this moved, so the workspace can redraw.
  final void Function(String sessionId)? onChanged;

  /// Rows given an ending. Diagnostics, and what the tests count.
  int written = 0;

  /// Applies [ending] to the row recording CLI conversation [agentSessionId].
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
