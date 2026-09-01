import '../../../core/database/app_database.dart';
import '../../../core/database/row_mapping.dart';
import '../domain/follow_up.dart';
import '../domain/session_ending.dart';

/// How many open follow-ups are ever handed to the inbox at once.
///
/// The same number and the same argument as `kAttentionInboxCap`: past a couple
/// of hundred, a list of things to come back to has stopped being a work queue
/// and become a log. Bounded **here**, at the source, rather than by the
/// inbox's own eviction — an evicted follow-up would be re-filed by the very
/// next sync with a fresh arrival time and would displace a survivor, forever.
const int kOpenFollowUpCap = 200;

/// Data-access for what sessions left behind (schema v25).
///
/// Four methods, and the shape of them is the point: a follow-up can be
/// **raised**, **read**, and **resolved**, and that is all. There is no update
/// — the words a follow-up was raised with are the source's own and must not be
/// quietly revised later — and no delete, because "why is this not in my list
/// any more?" deserves an answer, which is what [FollowUpResolution] is for.
class FollowUpDao {
  FollowUpDao(this._db);

  final AppDatabase _db;

  /// Records [followUp], or returns null when this session already has one
  /// open.
  ///
  /// Returning null rather than throwing, and rather than replacing: the caller
  /// is an observer that re-notices the same ended session on every revision
  /// bump, so "already known" is the *ordinary* outcome and must be cheap and
  /// silent. Replacing would be worse still — it would reset the age the user
  /// reads the list by every few seconds.
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

  /// Everything still waiting, newest first, at most [limit].
  ///
  /// Newest first because this is a work queue: the thing that just broke is
  /// the thing most likely to still be in the user's head.
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

  /// Closes [id], recording when and which way it went.
  ///
  /// A no-op on one already closed — `WHERE resolved_at IS NULL` — so a second
  /// call cannot overwrite the record of how it was closed the first time.
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
