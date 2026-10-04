import 'package:karmashala_session/session.dart';

import '../sessions/session_sync_rows.dart';

/// An ACP agent's name for its conversation (`session_info_update`), onto the
/// session row — unless a person named the row, which wins for good.
class AcpTitles {
  AcpTitles(this.rows);

  final SessionSyncRows rows;

  /// Whether [title] became the row's title; every client is told the row.
  bool follow(String sessionId, String title) {
    final named = title.trim();
    if (named.isEmpty) return false;
    final row = rows.sessions.getById(sessionId);
    if (row == null || row.titleByUser || row.title == named) return false;
    return rows.edit(sessionId, SessionPatch.rename(named)) != null;
  }
}
