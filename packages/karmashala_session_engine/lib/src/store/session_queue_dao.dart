import 'package:karmashala_session/session.dart';
import 'package:karmashala_store/database.dart';

/// Data access for `session_queued_messages`. Hand-written SQL; every state
/// move is guarded on the state it leaves, so two drains never deliver one row.
class SessionQueueDao {
  SessionQueueDao(this._db);

  final AppDatabase _db;

  static const _open = "('queued', 'delivering', 'failed')";
  static const _waiting = "('queued', 'delivering')";

  /// The origins that are the person, not another session or a schedule.
  static const personOrigins = {
    QueuedMessageOrigin.app,
    QueuedMessageOrigin.device,
    QueuedMessageOrigin.companion,
  };

  /// Queues a message after every other of [sessionId]'s — except that the
  /// person's own goes before what other sessions queued, behind only the
  /// person's earlier messages.
  QueuedMessage enqueue({
    required String id,
    required String sessionId,
    required String text,
    required QueuedMessageOrigin origin,
    required DateTime now,
    String? originId,
    String? requestId,
  }) => _db.transaction(() {
    final seq = personOrigins.contains(origin)
        ? _personSlot(sessionId)
        : _maxSeq(sessionId) + 1;
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

  int _maxSeq(String sessionId) =>
      _db.query(
            'SELECT MAX(seq) AS seq FROM session_queued_messages '
            'WHERE session_id = ?;',
            [sessionId],
          ).first['seq']
          as int? ??
      0;

  /// The seq a person's new message takes: just before the first message
  /// another session queued after the person's last queued one, with that
  /// one and every later row moved down by one; else the end.
  int _personSlot(String sessionId) {
    final people = [for (final o in personOrigins) o.name];
    final marks = List.filled(people.length, '?').join(', ');
    final lastOwn =
        _db.query(
              'SELECT MAX(seq) AS seq FROM session_queued_messages '
              "WHERE session_id = ? AND state = 'queued' "
              'AND origin IN ($marks);',
              [sessionId, ...people],
            ).first['seq']
            as int? ??
        0;
    final firstPeer =
        _db.query(
              'SELECT MIN(seq) AS seq FROM session_queued_messages '
              "WHERE session_id = ? AND state = 'queued' AND seq > ? "
              'AND origin NOT IN ($marks);',
              [sessionId, lastOwn, ...people],
            ).first['seq']
            as int?;
    if (firstPeer == null) return _maxSeq(sessionId) + 1;
    // In two steps, so no row passes through another's seq on the way.
    const away = 1 << 30;
    _db.execute(
      'UPDATE session_queued_messages SET seq = seq + ? '
      'WHERE session_id = ? AND seq >= ?;',
      [away, sessionId, firstPeer],
    );
    _db.execute(
      'UPDATE session_queued_messages SET seq = seq - ? '
      'WHERE session_id = ? AND seq >= ?;',
      [away - 1, sessionId, firstPeer + away],
    );
    return firstPeer;
  }

  QueuedMessage? getById(String id) {
    final rows = _db.query(
      'SELECT * FROM session_queued_messages WHERE id = ?;',
      [id],
    );
    return rows.isEmpty ? null : _row(rows.first);
  }

  /// The row a sender's [requestId] already queued for [sessionId], if any.
  /// One cancelled or failed is not: a retry under the same id goes again.
  QueuedMessage? byRequest(String sessionId, String requestId) {
    final rows = _db.query(
      'SELECT * FROM session_queued_messages WHERE session_id = ? '
      "AND request_id = ? AND state NOT IN ('cancelled', 'failed') LIMIT 1;",
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
  bool hasWaiting(String sessionId) => _db.query(
    'SELECT 1 FROM session_queued_messages WHERE session_id = ? '
    'AND state IN $_waiting LIMIT 1;',
    [sessionId],
  ).isNotEmpty;

  /// Whether [sessionId] has a message on its way, or one from [origins]
  /// still queued.
  bool hasWaitingFrom(String sessionId, Set<QueuedMessageOrigin> origins) {
    final names = [for (final origin in origins) origin.name];
    return _db.query(
      'SELECT 1 FROM session_queued_messages WHERE session_id = ? '
      "AND (state = 'delivering' OR (state = 'queued' AND origin IN "
      '(${List.filled(names.length, '?').join(', ')}))) LIMIT 1;',
      [sessionId, ...names],
    ).isNotEmpty;
  }

  /// The next message to deliver for [sessionId], or null.
  QueuedMessage? head(String sessionId) {
    final rows = _db.query(
      'SELECT * FROM session_queued_messages WHERE session_id = ? '
      "AND state = 'queued' ORDER BY seq LIMIT 1;",
      [sessionId],
    );
    return rows.isEmpty ? null : _row(rows.first);
  }

  /// How many of [sessionId]'s queued messages go no later than [seq]: one
  /// already on its way is not ahead of anything.
  int positionOf(String sessionId, int seq) =>
      _db.query(
            'SELECT COUNT(*) AS n FROM session_queued_messages '
            "WHERE session_id = ? AND state = 'queued' AND seq <= ?;",
            [sessionId, seq],
          ).first['n']
          as int;

  /// Every session with a message still queued.
  List<String> sessionsWithQueued() => [
    for (final row in _db.query(
      'SELECT DISTINCT session_id FROM session_queued_messages '
      "WHERE state = 'queued';",
    ))
      row['session_id']! as String,
  ];

  /// Moves [id] from [from] to [to], and says whether it did. A cancel names
  /// who asked for it in [cancelledBy].
  bool transition(
    String id, {
    required QueuedMessageState from,
    required QueuedMessageState to,
    required DateTime now,
    String? error,
    String? cancelledBy,
  }) {
    _db.execute(
      'UPDATE session_queued_messages SET state = ?, updated_at = ?, '
      'error = COALESCE(?, error), '
      'cancelled_by = COALESCE(?, cancelled_by), '
      'delivered_at = CASE WHEN ? THEN ? '
      'ELSE delivered_at END WHERE id = ? AND state = ?;',
      [
        to.name,
        isoFromDate(now),
        error,
        cancelledBy,
        intFromBool(to == QueuedMessageState.delivered),
        isoFromDate(now),
        id,
        from.name,
      ],
    );
    return _changed();
  }

  /// Puts [id] ahead of every other of its session's messages while it is
  /// still queued; false otherwise.
  bool moveToFront(String id) => _db.transaction(() {
    _db.execute(
      'UPDATE session_queued_messages SET seq = ('
      'SELECT MIN(seq) - 1 FROM session_queued_messages AS other '
      'WHERE other.session_id = session_queued_messages.session_id'
      ") WHERE id = ? AND state = 'queued';",
      [id],
    );
    return _changed();
  });

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
    cancelledBy: row['cancelled_by'] as String?,
  );
}
