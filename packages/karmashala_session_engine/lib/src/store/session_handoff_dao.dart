import 'package:karmashala_store/database.dart';

/// What a launch hands an agent beside its arguments.
enum HandoffKind {
  /// The opening message a person, an agent or an automation gave.
  opening,

  /// A handoff packet sent as the opening message: the agent takes no
  /// system-prompt file.
  packet,

  /// A handoff packet handed over as the agent's system prompt.
  systemPrompt,
}

/// How a handoff reached its agent.
enum HandoffRoute {
  /// On the command line.
  argv,

  /// Typed into the agent's composer once it was ready.
  typed,

  /// Written to a temporary file the agent was pointed at.
  file,

  /// As the first prompt of a protocol the agent speaks (ACP).
  protocol,
}

/// One row of `session_handoffs`.
class SessionHandoff {
  const SessionHandoff({
    required this.sessionId,
    required this.kind,
    required this.text,
    required this.route,
    required this.createdAt,
    this.consumedAt,
  });

  final String sessionId;
  final HandoffKind kind;
  final String text;
  final HandoffRoute route;
  final DateTime createdAt;

  /// When the agent had it; null while it waits.
  final DateTime? consumedAt;
}

/// Data access for `session_handoffs`: the table is the only copy of a text a
/// session was started with, so nothing on disk outlives its use.
class SessionHandoffDao {
  SessionHandoffDao(this._db);

  final AppDatabase _db;

  /// Writes [handoff] over any earlier one of its session and kind.
  void put(SessionHandoff handoff) => _db.execute(
    'INSERT OR REPLACE INTO session_handoffs (session_id, kind, text, route, '
    'created_at, consumed_at) VALUES (?, ?, ?, ?, ?, NULL);',
    [
      handoff.sessionId,
      handoff.kind.name,
      handoff.text,
      handoff.route.name,
      isoFromDate(handoff.createdAt),
    ],
  );

  SessionHandoff? get(String sessionId, HandoffKind kind) {
    final rows = _db.query(
      'SELECT * FROM session_handoffs WHERE session_id = ? AND kind = ?;',
      [sessionId, kind.name],
    );
    return rows.isEmpty ? null : _row(rows.first);
  }

  List<SessionHandoff> forSession(String sessionId) => [
    for (final row in _db.query(
      'SELECT * FROM session_handoffs WHERE session_id = ?;',
      [sessionId],
    ))
      ?_row(row),
  ];

  /// Every row not yet consumed, of [route] when given.
  List<SessionHandoff> pending({HandoffRoute? route}) => [
    for (final row in _db.query(
      'SELECT * FROM session_handoffs WHERE consumed_at IS NULL'
      '${route == null ? '' : ' AND route = ?'};',
      [?route?.name],
    ))
      ?_row(row),
  ];

  /// Marks [sessionId]'s unconsumed rows — of [kind] alone when given — used
  /// at [at], and says how many.
  int consume(String sessionId, {required DateTime at, HandoffKind? kind}) {
    _db.execute(
      'UPDATE session_handoffs SET consumed_at = ? WHERE session_id = ? '
      'AND consumed_at IS NULL${kind == null ? '' : ' AND kind = ?'};',
      [isoFromDate(at), sessionId, ?kind?.name],
    );
    return _changes();
  }

  /// Deletes rows consumed before [before], and unconsumed rows created
  /// before it whose session is not in [live]; says how many.
  int sweep({required DateTime before, required Set<String> live}) {
    final cutoff = isoFromDate(before);
    return _db.transaction(() {
      _db.execute(
        'DELETE FROM session_handoffs WHERE consumed_at IS NOT NULL '
        'AND consumed_at < ?;',
        [cutoff],
      );
      var removed = _changes();
      for (final row in _db.query(
        'SELECT session_id, kind FROM session_handoffs '
        'WHERE consumed_at IS NULL AND created_at < ?;',
        [cutoff],
      )) {
        final sessionId = row['session_id']! as String;
        if (live.contains(sessionId)) continue;
        _db.execute(
          'DELETE FROM session_handoffs WHERE session_id = ? AND kind = ?;',
          [sessionId, row['kind']],
        );
        removed += _changes();
      }
      return removed;
    });
  }

  int _changes() => _db.query('SELECT changes() AS n;').first['n']! as int;

  static SessionHandoff? _row(Map<String, Object?> row) {
    final kind = HandoffKind.values.asNameMap()[row['kind']];
    final route = HandoffRoute.values.asNameMap()[row['route']];
    if (kind == null || route == null) return null;
    final consumed = row['consumed_at'];
    return SessionHandoff(
      sessionId: row['session_id']! as String,
      kind: kind,
      text: row['text']! as String,
      route: route,
      createdAt: dateFromIso(row['created_at']),
      consumedAt: consumed == null ? null : dateFromIso(consumed),
    );
  }
}
