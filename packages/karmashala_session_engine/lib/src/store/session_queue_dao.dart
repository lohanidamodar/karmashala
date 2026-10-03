import 'package:karmashala_session/session.dart';
import 'package:karmashala_store/database.dart';

/// Data access for `session_queued_messages`. Hand-written SQL; every state
/// move is guarded on the state it leaves, so two drains never deliver one row.
class SessionQueueDao {
  SessionQueueDao(this._db);

  final AppDatabase _db;

  static const _open = "('queued', 'delivering', 'failed')";
  static const _waiting = "('queued', 'delivering')";

  /// Appends a message after every other of [sessionId]'s.
  QueuedMessage enqueue({
    required String id,
    required String sessionId,
    required String text,
    required QueuedMessageOrigin origin,
    required DateTime now,
    String? originId,
    String? requestId,
  }) => _db.transaction(() {
    final seq =
        (_db
                    .query(
                      'SELECT MAX(seq) AS seq FROM session_queued_messages '
                      'WHERE session_id = ?;',
                      [sessionId],
                    )
                    .first['seq']
                as int? ??
            0) +
        1;
    final message = QueuedMessage(
      id: id,
      sessionId: sessionId,
      seq: seq,
      text: text,
      state: QueuedMessageState.queued,
      origin: origin,
      originId: originId,
      createdAt: now,
      updatedAt: now,
      requestId: requestId,
    );
    _db.execute(
      'INSERT INTO session_queued_messages (id, session_id, seq, text, state, '
      'origin, origin_id, created_at, updated_at, request_id) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);',
      [
        id,
        sessionId,
        seq,
        text,
        message.state.name,
        origin.name,
        originId,
        isoFromDate(now),
        isoFromDate(now),
        requestId,
      ],
    );
    return message;
  });

  QueuedMessage? getById(String id) {
    final rows = _db.query(
      'SELECT * FROM session_queued_messages WHERE id = ?;',
      [id],
    );
    return rows.isEmpty ? null : _row(rows.first);
  }

  /// The row a sender's [requestId] already queued for [sessionId], if any.
  QueuedMessage? byRequest(String sessionId, String requestId) {
    final rows = _db.query(
      'SELECT * FROM session_queued_messages WHERE session_id = ? '
      'AND request_id = ? LIMIT 1;',
      [sessionId, requestId],
    );
    return rows.isEmpty ? null : _row(rows.first);
  }

  /// What a client shows for [sessionId]: queued, delivering and failed, in
  /// order.
  List<QueuedMessage> open(String sessionId) => _db
      .query(
        'SELECT * FROM session_queued_messages WHERE session_id = ? '
        'AND state IN $_open ORDER BY seq;',
        [sessionId],
      )
      .map(_row)
      .toList();

  /// Whether [sessionId] has a message still to deliver or on its way.
  bool hasWaiting(String sessionId) => _db
      .query(
        'SELECT 1 FROM session_queued_messages WHERE session_id = ? '
        'AND state IN $_waiting LIMIT 1;',
        [sessionId],
      )
      .isNotEmpty;

  /// The next message to deliver for [sessionId], or null.
  QueuedMessage? head(String sessionId) {
    final rows = _db.query(
      'SELECT * FROM session_queued_messages WHERE session_id = ? '
      "AND state = 'queued' ORDER BY seq LIMIT 1;",
      [sessionId],
    );
    return rows.isEmpty ? null : _row(rows.first);
  }

  /// How many of [sessionId]'s waiting messages go no later than [seq].
  int positionOf(String sessionId, int seq) =>
      _db
              .query(
                'SELECT COUNT(*) AS n FROM session_queued_messages '
                'WHERE session_id = ? AND state IN $_waiting AND seq <= ?;',
                [sessionId, seq],
              )
              .first['n']
          as int;

  /// Every session with a message still queued.
  List<String> sessionsWithQueued() => [
    for (final row in _db.query(
      'SELECT DISTINCT session_id FROM session_queued_messages '
      "WHERE state = 'queued';",
    ))
      row['session_id']! as String,
  ];

  /// Moves [id] from [from] to [to], and says whether it did.
  bool transition(
    String id, {
    required QueuedMessageState from,
    required QueuedMessageState to,
    required DateTime now,
    String? error,
  }) {
    _db.execute(
      'UPDATE session_queued_messages SET state = ?, updated_at = ?, '
      'error = COALESCE(?, error), delivered_at = CASE WHEN ? THEN ? '
      'ELSE delivered_at END WHERE id = ? AND state = ?;',
      [
        to.name,
        isoFromDate(now),
        error,
        intFromBool(to == QueuedMessageState.delivered),
        isoFromDate(now),
        id,
        from.name,
      ],
    );
    return _changed();
  }

  /// Replaces [id]'s text while it is still queued; false otherwise.
  bool editText(String id, String text, {required DateTime now}) {
    _db.execute(
      'UPDATE session_queued_messages SET text = ?, updated_at = ? '
      "WHERE id = ? AND state = 'queued';",
      [text, isoFromDate(now), id],
    );
    return _changed();
  }

  /// Fails every row a server that stopped mid-delivery left `delivering`,
  /// and returns the sessions they belong to. Never resent: the words may
  /// have reached the agent.
  Set<String> failInterrupted({required DateTime now, required String error}) =>
      _db.transaction(() {
        final sessions = {
          for (final row in _db.query(
            'SELECT DISTINCT session_id FROM session_queued_messages '
            "WHERE state = 'delivering';",
          ))
            row['session_id']! as String,
        };
        _db.execute(
          "UPDATE session_queued_messages SET state = 'failed', "
          "updated_at = ?, error = ? WHERE state = 'delivering';",
          [isoFromDate(now), error],
        );
        return sessions;
      });

  bool _changed() => _db.query('SELECT changes() AS n;').first['n'] == 1;

  QueuedMessage _row(Map<String, Object?> row) => QueuedMessage(
    id: row['id']! as String,
    sessionId: row['session_id']! as String,
    seq: row['seq']! as int,
    text: row['text'] as String? ?? '',
    state: QueuedMessageState.fromName(row['state'] as String?),
    origin: QueuedMessageOrigin.fromName(row['origin'] as String?),
    originId: row['origin_id'] as String?,
    createdAt: dateFromIso(row['created_at']),
    updatedAt: dateFromIso(row['updated_at']),
    deliveredAt: row['delivered_at'] == null
        ? null
        : dateFromIso(row['delivered_at']),
    requestId: row['request_id'] as String?,
    error: row['error'] as String?,
  );
}
