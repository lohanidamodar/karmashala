import '../../../core/database/app_database.dart';
import '../../../core/database/row_mapping.dart';
import '../domain/decision_record.dart';

/// Data-access for the **append-only** decision record (schema v23).
///
/// The surface is deliberately three methods: [append] and two reads. There is
/// no update and no delete, and that is the feature rather than an omission —
/// the record's whole value is that what was decided cannot later be quietly
/// revised into what is convenient now. `SessionEventDao` makes the same
/// argument about the event log (ADR 0003); this one matters more, because a
/// decision is read by an agent that was not there and has no way to check it.
///
/// A second write of an identical decision therefore appends a **second row**.
/// It does not find and rewrite the first: two people deciding the same thing
/// twice is two acts, and collapsing them would silently discard when it was
/// re-affirmed.
class DecisionRecordDao {
  DecisionRecordDao(this._db);

  final AppDatabase _db;

  /// Appends [decision] to its session's record, assigning the next sequence
  /// number, and returns it with that number and its database id filled in.
  ///
  /// Sequenced inside a transaction against a unique index, so two writers
  /// cannot both claim position 4 — which is what makes the chain readable as
  /// an order rather than a bag.
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

  /// Every decision recorded for [sessionId], **oldest first**.
  ///
  /// Oldest first because decisions accumulate into a position: the early ones
  /// are the constraints everything since was built on, and reading them in
  /// reverse would present the conclusions before the rules they follow from.
  List<DecisionRecord> forSession(String sessionId) {
    final rows = _db.query(
      'SELECT * FROM session_decisions WHERE session_id = ? ORDER BY sequence;',
      [sessionId],
    );
    return rows.map(_fromRow).toList();
  }

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
