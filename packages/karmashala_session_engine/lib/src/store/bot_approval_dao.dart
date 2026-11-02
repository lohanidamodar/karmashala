import 'dart:convert';

import 'package:karmashala_session/session.dart'
    show BotApproval, BotApprovalState;
import 'package:karmashala_store/database.dart';

/// Data-access for what the bot asked a person to approve. Every move out of
/// `pending` is one conditional statement, so of any two a single one wins:
/// that is what makes Yes run the recorded call exactly once.
class BotApprovalDao {
  BotApprovalDao(this._db);

  final AppDatabase _db;

  void insert(BotApproval approval) {
    _db.execute(
      'INSERT INTO bot_approvals (id, session_id, tool, arguments, summary, '
      'state, requested_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?);',
      [
        approval.id,
        approval.sessionId,
        approval.tool,
        jsonEncode(approval.arguments),
        approval.summary,
        approval.state.name,
        isoFromDate(approval.requestedAt),
        isoFromDate(approval.expiresAt),
      ],
    );
  }

  BotApproval? getById(String id) {
    final rows = _db.query('SELECT * FROM bot_approvals WHERE id = ?;', [id]);
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  /// Takes [id] from pending to [to], unless it is no longer pending or its
  /// time passed before [at]. Answers it then, or null when it was not moved.
  BotApproval? consume(
    String id, {
    required BotApprovalState to,
    required DateTime at,
    required String by,
  }) {
    final moved = _changes(
      () => _db.execute(
        'UPDATE bot_approvals SET state = ?, decided_at = ?, decided_by = ? '
        'WHERE id = ? AND state = ? AND expires_at >= ?;',
        [
          to.name,
          isoFromDate(at),
          by,
          id,
          BotApprovalState.pending.name,
          isoFromDate(at),
        ],
      ),
    );
    return moved == 0 ? null : getById(id);
  }

  /// [id] as it ended, with what became of it in words.
  void finish(
    String id, {
    required BotApprovalState state,
    required String outcome,
  }) {
    _db.execute(
      'UPDATE bot_approvals SET state = ?, outcome = ? WHERE id = ?;',
      [state.name, outcome, id],
    );
  }

  /// [sessionId]'s requests still waiting, oldest first.
  List<BotApproval> pending(String sessionId) => _db
      .query(
        'SELECT * FROM bot_approvals WHERE session_id = ? AND state = ? '
        'ORDER BY requested_at, id;',
        [sessionId, BotApprovalState.pending.name],
      )
      .map(_fromRow)
      .toList();

  /// Calls being run: at a start, those a stop cut off.
  List<BotApproval> running() => _db
      .query(
        'SELECT * FROM bot_approvals WHERE state = ? ORDER BY requested_at;',
        [BotApprovalState.running.name],
      )
      .map(_fromRow)
      .toList();

  /// Expires every pending request past its time at [now], and answers them.
  List<BotApproval> expireDue(DateTime now) => _expire(
    _db
        .query(
          'SELECT id FROM bot_approvals WHERE state = ? AND expires_at < ?;',
          [BotApprovalState.pending.name, isoFromDate(now)],
        )
        .map((row) => row['id']! as String),
    now,
  );

  /// Expires every pending request of [sessionId], whatever its time.
  List<BotApproval> expireAll(String sessionId, {required DateTime at}) =>
      _expire(pending(sessionId).map((approval) => approval.id), at);

  List<BotApproval> _expire(Iterable<String> ids, DateTime at) => [
    for (final id in ids.toList())
      if (_changes(
            () => _db.execute(
              'UPDATE bot_approvals SET state = ?, decided_at = ? '
              'WHERE id = ? AND state = ?;',
              [
                BotApprovalState.expired.name,
                isoFromDate(at),
                id,
                BotApprovalState.pending.name,
              ],
            ),
          ) >
          0)
        getById(id)!,
  ];

  int _changes(void Function() write) {
    int total() => _db.query('SELECT total_changes() AS n;').first['n']! as int;
    final before = total();
    write();
    return total() - before;
  }

  BotApproval _fromRow(Map<String, Object?> row) => BotApproval(
    id: row['id']! as String,
    sessionId: row['session_id']! as String,
    tool: row['tool']! as String,
    arguments: (jsonDecode(row['arguments']! as String) as Map)
        .cast<String, Object?>(),
    summary: row['summary']! as String,
    state: BotApprovalState.parse(row['state'] as String?),
    requestedAt: dateFromIso(row['requested_at']),
    expiresAt: dateFromIso(row['expires_at']),
    decidedAt: row['decided_at'] == null
        ? null
        : dateFromIso(row['decided_at']),
    decidedBy: row['decided_by'] as String?,
    outcome: row['outcome'] as String?,
  );
}
