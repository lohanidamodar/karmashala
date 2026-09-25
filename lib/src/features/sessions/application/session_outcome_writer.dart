import 'package:riverpod/riverpod.dart';

import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:karmashala_session/session.dart';
import 'session_providers.dart';
import 'session_signals.dart';

/// **Writes a session row's ending from what the agent said, and nothing
/// else** — never from a pane's exit code, and never over a terminal word.
class SessionOutcomeWriter {
  SessionOutcomeWriter({required this.sessionDao, this.onChanged});

  final SessionDao sessionDao;

  /// Called with each row this moved, so the workspace can redraw.
  final void Function(String sessionId)? onChanged;

  /// Rows given an ending. Diagnostics, and what the tests count.
  int written = 0;

  /// Applies [ending] to the row recording conversation [agentSessionId], and
  /// returns the row id it wrote — null, the common case, is not a failure.
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
      // A `/clear` or `/resume`: the pane lives on, and an ended row is final.
      AgentSessionEnding.conversationOnly => null,
    };
    if (status == null) return null;
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
