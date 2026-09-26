import 'package:karmashala_session/events.dart';
import 'package:karmashala_store/database.dart';

/// The `session_relays` record: append-only, so "who told this session to do
/// that" survives a restart (docs/inter-agent-communication.md §4.2).
class SessionRelayDao {
  SessionRelayDao(this._db);

  final AppDatabase _db;

  void record(SessionRelay relay) => _db.execute(
    'INSERT INTO session_relays '
    '(from_session_id, to_session_id, text, created_at) VALUES (?, ?, ?, ?);',
    [relay.fromSessionId, relay.toSessionId, relay.text, isoFromDate(relay.at)],
  );

  /// How many times [from] has sent to [to] since [since].
  int countBetween(String from, String to, {required DateTime since}) =>
      _db.query(
            'SELECT COUNT(*) AS n FROM session_relays '
            'WHERE from_session_id = ? AND to_session_id = ? '
            'AND created_at >= ?;',
            [from, to, isoFromDate(since)],
          ).first['n']!
          as int;

  /// The most recent [limit] relays into [to], oldest first, and how many
  /// there are in all.
  ({List<SessionRelay> relays, int total}) recentTo(String to, int limit) {
    final total =
        _db.query(
              'SELECT COUNT(*) AS n FROM session_relays '
              'WHERE to_session_id = ?;',
              [to],
            ).first['n']!
            as int;
    final rows = _db.query(
      'SELECT * FROM session_relays WHERE to_session_id = ? '
      'ORDER BY id DESC LIMIT ?;',
      [to, limit],
    );
    return (
      relays: [
        for (final row in rows.reversed)
          SessionRelay(
            fromSessionId: row['from_session_id']! as String,
            toSessionId: row['to_session_id']! as String,
            text: row['text']! as String,
            at: dateFromIso(row['created_at']),
          ),
      ],
      total: total,
    );
  }
}
