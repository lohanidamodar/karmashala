import 'package:karmashala_store/database.dart';
import '../domain/follow_up.dart';
import '../domain/session_ending.dart';

/// How many open follow-ups are ever handed to the inbox at once. Bounded
/// here, at the source: an evicted one would be re-filed by the next sync.
const int kOpenFollowUpCap = 200;

/// Data-access for what sessions left behind. A follow-up can be raised, read
/// and resolved — no update, and no delete, so a disappearance has an answer.
class FollowUpDao {
  FollowUpDao(this._db);

  final AppDatabase _db;

  /// Records [followUp], or returns null when this session already has one open.
  /// Replacing would reset the age the user reads the list by.
  FollowUp? raise(FollowUp followUp) {
    return _db.transaction(() {
      final open = _db.query(
        'SELECT 1 FROM session_follow_ups '
        'WHERE session_id = ? AND resolved_at IS NULL LIMIT 1;',
        [followUp.sessionId],
      );
      if (open.isNotEmpty) return null;

      _db.execute(
        'INSERT INTO session_follow_ups '
        '(session_id, reason, ending, summary, raised_at) '
        'VALUES (?, ?, ?, ?, ?);',
        [
          followUp.sessionId,
          followUp.reason.name,
          followUp.ending.name,
          followUp.summary,
          isoFromDate(followUp.raisedAt),
        ],
      );
      return followUp.copyWith(id: _db.lastInsertRowId);
    });
  }

  /// Everything still waiting, newest first, at most [limit] — a work queue, so
  /// the thing that just broke is the thing still in the user's head.
  List<FollowUp> open({int limit = kOpenFollowUpCap}) {
    final rows = _db.query(
      'SELECT * FROM session_follow_ups WHERE resolved_at IS NULL '
      'ORDER BY raised_at DESC, id DESC LIMIT ?;',
      [limit],
    );
    return rows.map(_fromRow).toList();
  }

  /// The open follow-up for [sessionId], or null.
  FollowUp? openForSession(String sessionId) {
    final rows = _db.query(
      'SELECT * FROM session_follow_ups '
      'WHERE session_id = ? AND resolved_at IS NULL LIMIT 1;',
      [sessionId],
    );
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  /// Closes [id], recording when and which way it went. A no-op on one already
  /// closed, so a second call cannot overwrite the first record.
  void resolve(
    int id, {
    required FollowUpResolution resolution,
    required DateTime at,
  }) {
    _db.execute(
      'UPDATE session_follow_ups SET resolved_at = ?, resolution = ? '
      'WHERE id = ? AND resolved_at IS NULL;',
      [isoFromDate(at), resolution.name, id],
    );
  }

  /// `'<sessionId>/<ending>'` for every ending that has ever produced a row,
  /// open or resolved. One query per app run, so the sweep needs none per session.
  Set<String> raisedEndings() {
    final rows = _db.query(
      'SELECT DISTINCT session_id, ending FROM session_follow_ups;',
    );
    return {
      for (final row in rows) '${row['session_id']}/${row['ending']}',
    };
  }

  FollowUp _fromRow(Map<String, Object?> row) => FollowUp(
    id: row['id']! as int,
    sessionId: row['session_id']! as String,
    reason: FollowUpReason.fromName(row['reason'] as String?),
    ending: SessionEnding.fromName(row['ending'] as String?),
    summary: row['summary'] as String?,
    raisedAt: dateFromIso(row['raised_at']),
    resolvedAt: row['resolved_at'] == null
        ? null
        : dateFromIso(row['resolved_at']),
    resolution: FollowUpResolution.fromName(row['resolution'] as String?),
  );
}
