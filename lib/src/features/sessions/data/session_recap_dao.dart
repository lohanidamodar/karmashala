import '../../../core/database/app_database.dart';
import '../../../core/database/row_mapping.dart';
import '../domain/session_recap.dart';

/// Data-access for the recap one session was asked for (schema v48).
///
/// Three methods and no history. [write] replaces the row rather than appending
/// beside it — see the v48 migration for why a second recap is not a second
/// fact. `DecisionRecordDao` argues the opposite about decisions, and the
/// difference is the point: a decision is an act, a recap is a reading, and a
/// stale reading kept beside a fresh one is two answers to one question.
class SessionRecapDao {
  SessionRecapDao(this._db);

  final AppDatabase _db;

  /// Stores [recap], replacing whatever this session had.
  void write(SessionRecap recap) {
    _db.execute(
      'INSERT INTO session_recaps '
      '(session_id, text, agent_id, model, turn_count, written_at) '
      'VALUES (?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(session_id) DO UPDATE SET '
      'text = excluded.text, agent_id = excluded.agent_id, '
      'model = excluded.model, turn_count = excluded.turn_count, '
      'written_at = excluded.written_at;',
      [
        recap.sessionId,
        recap.text,
        recap.agentId,
        recap.model,
        recap.turnCount,
        isoFromDate(recap.writtenAt),
      ],
    );
  }

  /// The recap [sessionId] holds, or null when nobody has asked for one.
  SessionRecap? forSession(String sessionId) {
    final rows = _db.query(
      'SELECT * FROM session_recaps WHERE session_id = ?;',
      [sessionId],
    );
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  /// Drops [sessionId]'s recap. Used when a person dismisses one; a deleted
  /// session takes its own with it through the foreign key.
  void delete(String sessionId) {
    _db.execute('DELETE FROM session_recaps WHERE session_id = ?;', [
      sessionId,
    ]);
  }

  SessionRecap _fromRow(Map<String, Object?> row) => SessionRecap(
    sessionId: row['session_id']! as String,
    text: row['text']! as String,
    agentId: row['agent_id']! as String,
    model: row['model'] as String?,
    turnCount: row['turn_count']! as int,
    writtenAt: dateFromIso(row['written_at']),
  );
}
