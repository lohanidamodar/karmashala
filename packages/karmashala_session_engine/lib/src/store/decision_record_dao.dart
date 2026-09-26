import 'package:karmashala_store/database.dart';
import 'package:karmashala_session/events.dart';

/// Data-access for the **append-only** decision record (schema v23). No update
/// and no delete; a second identical decision appends a second row.
class DecisionRecordDao {
  DecisionRecordDao(this._db);

  final AppDatabase _db;

  /// Appends [decision], assigning the next sequence number and returning it
  /// filled in. Sequenced in a transaction, so two writers cannot share a slot.
  DecisionRecord append(DecisionRecord decision) {
    return _db.transaction(() {
      final rows = _db.query(
        'SELECT COALESCE(MAX(sequence), 0) AS max_seq FROM session_decisions '
        'WHERE session_id = ?;',
        [decision.sessionId],
      );
      final sequence = (rows.first['max_seq']! as int) + 1;

      _db.execute(
        'INSERT INTO session_decisions '
        '(session_id, sequence, kind, summary, detail, decided_by, '
        'recorded_by_session_id, origin_kind, origin_id, recorded_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);',
        [
          decision.sessionId,
          sequence,
          decision.kind.name,
          decision.summary,
          decision.detail,
          decision.decidedBy,
          decision.recordedBySessionId,
          decision.origin.name,
          decision.originId,
          isoFromDate(decision.recordedAt),
        ],
      );

      return decision.copyWith(id: _db.lastInsertRowId, sequence: sequence);
    });
  }

  /// Every decision recorded for [sessionId], **oldest first**: reading them in
  /// reverse presents conclusions before the rules they follow from.
  List<DecisionRecord> forSession(String sessionId) {
    final rows = _db.query(
      'SELECT * FROM session_decisions WHERE session_id = ? ORDER BY sequence;',
      [sessionId],
    );
    return rows.map(_fromRow).toList();
  }

  /// Every decision ever recorded, each session's oldest first — a client's
  /// snapshot.
  List<DecisionRecord> all() => _db
      .query('SELECT * FROM session_decisions ORDER BY session_id, sequence;')
      .map(_fromRow)
      .toList();

  /// How many decisions [sessionId] has recorded.
  int countForSession(String sessionId) {
    final rows = _db.query(
      'SELECT COUNT(*) AS n FROM session_decisions WHERE session_id = ?;',
      [sessionId],
    );
    return rows.first['n']! as int;
  }

  DecisionRecord _fromRow(Map<String, Object?> row) => DecisionRecord(
    id: row['id']! as int,
    sessionId: row['session_id']! as String,
    sequence: row['sequence']! as int,
    kind: DecisionKind.fromName(row['kind'] as String?),
    summary: row['summary']! as String,
    detail: row['detail'] as String?,
    decidedBy: row['decided_by'] as String?,
    recordedBySessionId: row['recorded_by_session_id'] as String?,
    origin: DecisionOrigin.fromName(row['origin_kind'] as String?),
    originId: row['origin_id'] as String?,
    recordedAt: dateFromIso(row['recorded_at']),
  );
}
