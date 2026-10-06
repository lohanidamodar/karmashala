import 'package:karmashala_store/database.dart';

/// An async child whose turn results are pushed to its parent: which of its
/// turns the parent awaits ([turn]), and since when ([turnStartedAt]; null
/// when none is awaited until the parent sends a follow-up).
class SessionDelegation {
  const SessionDelegation({
    required this.childSessionId,
    required this.parentSessionId,
    required this.title,
    required this.agent,
    required this.delegatedAt,
    required this.turn,
    this.model,
    this.endOnAnswer = false,
    this.turnStartedAt,
  });

  final String childSessionId;
  final String parentSessionId;
  final String title;
  final String agent;
  final String? model;
  final bool endOnAnswer;
  final DateTime delegatedAt;
  final int turn;
  final DateTime? turnStartedAt;

  bool get awaiting => turnStartedAt != null;
}

/// Data access for `session_delegations`. Hand-written SQL.
class SessionDelegationDao {
  SessionDelegationDao(this._db);

  final AppDatabase _db;

  void put(SessionDelegation d) => _db.execute(
    'INSERT OR REPLACE INTO session_delegations (child_session_id, '
    'parent_session_id, title, agent, model, end_on_answer, delegated_at, '
    'turn, turn_started_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);',
    [
      d.childSessionId,
      d.parentSessionId,
      d.title,
      d.agent,
      d.model,
      d.endOnAnswer ? 1 : 0,
      isoFromDate(d.delegatedAt),
      d.turn,
      d.turnStartedAt == null ? null : isoFromDate(d.turnStartedAt!),
    ],
  );

  SessionDelegation? byChild(String childSessionId) {
    final rows = _db.query(
      'SELECT * FROM session_delegations WHERE child_session_id = ?;',
      [childSessionId],
    );
    return rows.isEmpty ? null : _row(rows.first);
  }

  List<SessionDelegation> forParent(String parentSessionId) => _db
      .query(
        'SELECT * FROM session_delegations WHERE parent_session_id = ? '
        'ORDER BY delegated_at;',
        [parentSessionId],
      )
      .map(_row)
      .toList();

  /// Every delegation, oldest first.
  List<SessionDelegation> all() => _db
      .query('SELECT * FROM session_delegations ORDER BY delegated_at;')
      .map(_row)
      .toList();

  /// Every delegation whose parent awaits a turn, oldest first.
  List<SessionDelegation> awaiting() => _db
      .query(
        'SELECT * FROM session_delegations WHERE turn_started_at IS NOT NULL '
        'ORDER BY delegated_at;',
      )
      .map(_row)
      .toList();

  /// Clears the awaited [turn] once its result went; false when another turn
  /// is awaited by now (or none).
  bool turnReported(String childSessionId, {required int turn}) {
    _db.execute(
      'UPDATE session_delegations SET turn_started_at = NULL '
      'WHERE child_session_id = ? AND turn = ? '
      'AND turn_started_at IS NOT NULL;',
      [childSessionId, turn],
    );
    return _changed();
  }

  /// Awaits [childSessionId]'s next turn from [since]; null when it is no
  /// delegation.
  SessionDelegation? awaitNextTurn(
    String childSessionId, {
    required DateTime since,
  }) {
    _db.execute(
      'UPDATE session_delegations SET turn = turn + 1, turn_started_at = ? '
      'WHERE child_session_id = ?;',
      [isoFromDate(since), childSessionId],
    );
    return _changed() ? byChild(childSessionId) : null;
  }

  void remove(String childSessionId) => _db.execute(
    'DELETE FROM session_delegations WHERE child_session_id = ?;',
    [childSessionId],
  );

  bool _changed() =>
      (_db.query('SELECT changes() AS n;').first['n'] as int? ?? 0) > 0;

  static SessionDelegation _row(Map<String, Object?> row) => SessionDelegation(
    childSessionId: row['child_session_id']! as String,
    parentSessionId: row['parent_session_id']! as String,
    title: row['title']! as String,
    agent: row['agent']! as String,
    model: row['model'] as String?,
    endOnAnswer: row['end_on_answer'] == 1,
    delegatedAt: dateFromIso(row['delegated_at']! as String),
    turn: row['turn']! as int,
    turnStartedAt: switch (row['turn_started_at']) {
      final String at => dateFromIso(at),
      _ => null,
    },
  );
}
