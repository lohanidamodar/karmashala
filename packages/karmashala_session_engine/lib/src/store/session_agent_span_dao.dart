import 'package:karmashala_session/session.dart';
import 'package:karmashala_store/database.dart';

import 'session_dao.dart';

/// Data access for `session_agent_spans`. Hand-written SQL.
class SessionAgentSpanDao {
  SessionAgentSpanDao(this._db);

  final AppDatabase _db;

  /// [sessionId]'s spans in switch order; empty for a one-agent session.
  List<SessionAgentSpan> forSession(String sessionId) => _db
      .query(
        'SELECT * FROM session_agent_spans WHERE session_id = ? ORDER BY seq;',
        [sessionId],
      )
      .map(_row)
      .toList();

  /// Whether [sessionId] has ever switched agent.
  bool hasSpans(String sessionId) => _db.query(
    'SELECT 1 FROM session_agent_spans WHERE session_id = ? LIMIT 1;',
    [sessionId],
  ).isNotEmpty;

  /// Records a switch of [session] to [toInstallationId] and points the row
  /// at it, in one transaction: span 0 for the agent leaving when this is the
  /// first switch, the leaving span's conversation as the row names it now,
  /// then the new span. Answers the new span.
  SessionAgentSpan recordSwitch({
    required Session session,
    required String toInstallationId,
    required String? toExternalSessionId,
    required DateTime at,
    int? firstMessageOrdinal,
    int? leavingFirstMessageOrdinal,
    String? carriedPacket,
  }) => _db.transaction(() {
    final spans = forSession(session.id);
    if (spans.isEmpty) {
      _insert(
        SessionAgentSpan(
          sessionId: session.id,
          seq: 0,
          agentInstallationId: session.agentInstallationId,
          externalSessionId: session.externalSessionId,
          startedAt: session.createdAt,
          firstMessageOrdinal: leavingFirstMessageOrdinal,
        ),
      );
    } else if (session.externalSessionId != null) {
      _db.execute(
        'UPDATE session_agent_spans SET external_session_id = ? '
        'WHERE session_id = ? AND seq = ?;',
        [session.externalSessionId, session.id, spans.last.seq],
      );
    }
    final next = SessionAgentSpan(
      sessionId: session.id,
      seq: spans.isEmpty ? 1 : spans.last.seq + 1,
      agentInstallationId: toInstallationId,
      externalSessionId: toExternalSessionId,
      startedAt: at,
      firstMessageOrdinal: firstMessageOrdinal,
      carriedPacket: carriedPacket,
    );
    _insert(next);
    SessionDao(_db).switchAgent(
      session.id,
      installationId: toInstallationId,
      externalSessionId: toExternalSessionId,
    );
    return next;
  });

  /// Takes back a switch whose new agent never started: the spans from
  /// [fromSeq] on go, and the row names [previous]'s agent again.
  void undoSwitch(Session previous, {required int fromSeq}) =>
      _db.transaction(() {
        _db.execute(
          'DELETE FROM session_agent_spans WHERE session_id = ? AND seq >= ?;',
          [previous.id, fromSeq],
        );
        SessionDao(_db).switchAgent(
          previous.id,
          installationId: previous.agentInstallationId,
          externalSessionId: previous.externalSessionId,
        );
      });

  void _insert(SessionAgentSpan span) => _db.execute(
    'INSERT INTO session_agent_spans (session_id, seq, agent_installation_id, '
    'external_session_id, started_at, first_message_ordinal, carried_packet) '
    'VALUES (?, ?, ?, ?, ?, ?, ?);',
    [
      span.sessionId,
      span.seq,
      span.agentInstallationId,
      span.externalSessionId,
      isoFromDate(span.startedAt),
      span.firstMessageOrdinal,
      span.carriedPacket,
    ],
  );

  static SessionAgentSpan _row(Map<String, Object?> row) => SessionAgentSpan(
    sessionId: row['session_id']! as String,
    seq: row['seq']! as int,
    agentInstallationId: row['agent_installation_id']! as String,
    externalSessionId: row['external_session_id'] as String?,
    startedAt: dateFromIso(row['started_at']),
    firstMessageOrdinal: row['first_message_ordinal'] as int?,
    carriedPacket: row['carried_packet'] as String?,
  );
}
