import '../../../core/database/app_database.dart';
import '../../../core/database/row_mapping.dart';
import 'package:karmashala_session/events.dart';

/// Data-access for the **append-only** session event log. No update or delete
/// (ADR 0003); [append] assigns the next per-session sequence atomically.
class SessionEventDao {
  SessionEventDao(this._db);

  final AppDatabase _db;

  /// Appends an event, assigning the next sequence number. The input's `seq` is
  /// ignored — computed here — while `createdAt` comes from the event.
  SessionEvent append(SessionEvent event) {
    return _db.transaction(() {
      final maxRows = _db.query(
        'SELECT COALESCE(MAX(seq), -1) AS max_seq FROM session_events '
        'WHERE session_id = ?;',
        [event.sessionId],
      );
      final nextSeq = (maxRows.first['max_seq']! as int) + 1;

      _db.execute(
        'INSERT INTO session_events '
        '(session_id, seq, type, payload, created_at) VALUES (?, ?, ?, ?, ?);',
        [
          event.sessionId,
          nextSeq,
          event.type,
          event.payload,
          isoFromDate(event.createdAt),
        ],
      );

      return event.copyWith(id: _db.lastInsertRowId, seq: nextSeq);
    });
  }

  /// All events for [sessionId], in append order.
  List<SessionEvent> listForSession(String sessionId) {
    final rows = _db.query(
      'SELECT * FROM session_events WHERE session_id = ? ORDER BY seq;',
      [sessionId],
    );
    return rows.map(_fromRow).toList();
  }

  /// Number of events recorded for [sessionId].
  int countForSession(String sessionId) {
    final rows = _db.query(
      'SELECT COUNT(*) AS n FROM session_events WHERE session_id = ?;',
      [sessionId],
    );
    return rows.first['n']! as int;
  }

  SessionEvent _fromRow(Map<String, Object?> row) => SessionEvent(
    id: row['id']! as int,
    sessionId: row['session_id']! as String,
    seq: row['seq']! as int,
    type: row['type']! as String,
    payload: row['payload']! as String,
    createdAt: dateFromIso(row['created_at']),
  );
}
