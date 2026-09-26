import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala_session/session.dart';

import 'session_sync_rows.dart';

/// Copies an agent's own name for a conversation — its title, a `/rename` —
/// into the session row on it, but only while the row carries a name nobody
/// typed. A person's rename (`titleByUser`) stops it for good.
class TitleSync {
  TitleSync({
    required this.rows,
    this.agents = AgentRegistry.builtIn,
    this.isRunning = _nowhere,
  });

  final SessionSyncRows rows;
  final AgentRegistry agents;

  /// Whether session [id]'s agent runs now — a host session the server
  /// holds, or a live pane a client reported running it: the observed
  /// answer, which a row's recorded status can lag behind.
  final bool Function(Session row) isRunning;

  /// Rows renamed, over this sync's life.
  int renames = 0;

  /// Whether a store scan would have anything to rename.
  bool get wantsStoreSweep => _waiting().isNotEmpty;

  /// Renames every waiting row its agent's store has a name for, from
  /// [detected] — one pass's scan. Returns how many.
  int sync(List<DetectedSession> detected) {
    final waiting = _waiting();
    if (waiting.isEmpty) return 0;
    final byConversation = {
      for (final session in detected) session.sessionId: session,
    };
    var renamed = 0;
    for (final row in waiting) {
      final match = byConversation[row.externalSessionId];
      if (match == null) continue;
      // `title`, never `displayTitle`: that falls back to the first message,
      // and writing a preview would settle the row against a real name.
      final title = match.title?.trim() ?? '';
      if (title.isEmpty || title == row.title) continue;
      if (rows.edit(row.id, SessionPatch.rename(title)) == null) continue;
      renames++;
      renamed++;
    }
    return renamed;
  }

  List<Session> _waiting() => [
    for (final row in rows.sessions.getWaitingForTitleSync())
      if (_waitingForAName(row)) row,
  ];

  bool _waitingForAName(Session row) {
    // Recorded on the row, not inferred in memory, or a restart makes every
    // title look like a person's.
    if (row.titleByUser) return false;
    final title = row.title.trim();
    if (isPlaceholderSessionTitle(title)) return true;
    for (final descriptor in agents.descriptors) {
      if (title == descriptor.displayName) return true;
    }
    // An agent's own name stays its to change, but only while the session
    // runs: a stopped one would buy a store scan on every pass for ever.
    return row.status == SessionStatus.running || isRunning(row);
  }
}

bool _nowhere(Session _) => false;
