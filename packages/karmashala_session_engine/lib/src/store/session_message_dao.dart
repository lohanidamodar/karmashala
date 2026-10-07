import 'dart:convert';

import 'package:karmashala_store/database.dart';

/// Who a stored message is from. A [notice] or an [error] is neither side's
/// turn but a note the session made: a hook's message, a turn that failed.
enum SessionMessageRole { user, agent, tool, notice, error }

/// One row of `session_messages`: a turn of an ACP session's conversation as
/// the server stored it. [ordinal] and [revision] are the
/// DAO's to assign; a message handed to [SessionMessageDao.append] carries
/// whatever, and comes back with the real ones.
class SessionMessage {
  const SessionMessage({
    required this.id,
    required this.sessionId,
    required this.role,
    required this.createdAt,
    required this.updatedAt,
    this.ordinal = -1,
    this.text = '',
    this.thinking,
    this.toolJson,
    this.planJson,
    this.messageId,
    this.revision = 0,
    this.model,
  });

  final String id;
  final String sessionId;
  final SessionMessageRole role;

  /// The row's place in its session, 0-based and contiguous.
  final int ordinal;
  final String text;
  final String? thinking;

  /// The tool call, as JSON: `toolCallId, title, name, kind, status,
  /// locations, content, rawInput, rawOutput`.
  final String? toolJson;

  /// The plan the agent published at this row, as JSON.
  final String? planJson;

  /// The agent's own id for the message, when it gave one.
  final String? messageId;

  /// The session's revision when this row last changed.
  final int revision;

  /// The model the agent said it was running when it wrote an agent row.
  final String? model;
  final DateTime createdAt;
  final DateTime updatedAt;

  SessionMessage copyWith({
    int? ordinal,
    String? text,
    String? thinking,
    String? toolJson,
    String? planJson,
    String? messageId,
    int? revision,
    DateTime? updatedAt,
    String? model,
  }) => SessionMessage(
    id: id,
    sessionId: sessionId,
    role: role,
    ordinal: ordinal ?? this.ordinal,
    text: text ?? this.text,
    thinking: thinking ?? this.thinking,
    toolJson: toolJson ?? this.toolJson,
    planJson: planJson ?? this.planJson,
    messageId: messageId ?? this.messageId,
    revision: revision ?? this.revision,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    model: model ?? this.model,
  );
}

/// Data-access for `session_messages`. Every write — [append] or [patch] —
/// moves the session's revision to `max(revision) + 1`, in the same
/// transaction, so a reader holding a revision is sent exactly what moved.
class SessionMessageDao {
  SessionMessageDao(this._db, {DateTime Function()? now})
    : _now = now ?? (() => DateTime.now().toUtc());

  final AppDatabase _db;
  final DateTime Function() _now;

  /// Appends [message] at the session's next ordinal and revision.
  SessionMessage append(SessionMessage message) {
    return _db.transaction(() {
      final next = _db.query(
        'SELECT COALESCE(MAX(ordinal), -1) + 1 AS ordinal, '
        'COALESCE(MAX(revision), 0) + 1 AS revision '
        'FROM session_messages WHERE session_id = ?;',
        [message.sessionId],
      ).first;
      final ordinal = next['ordinal']! as int;
      final revision = next['revision']! as int;
      _db.execute(
        'INSERT INTO session_messages (id, session_id, ordinal, role, text, '
        'thinking, tool_json, plan_json, message_id, revision, created_at, '
        'updated_at, model) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);',
        [
          message.id,
          message.sessionId,
          ordinal,
          message.role.name,
          message.text,
          message.thinking,
          message.toolJson,
          message.planJson,
          message.messageId,
          revision,
          isoFromDate(message.createdAt),
          isoFromDate(message.updatedAt),
          message.model,
        ],
      );
      return message.copyWith(ordinal: ordinal, revision: revision);
    });
  }

  /// Changes row [id] and bumps its session's revision. [text] replaces,
  /// [appendText] adds to the end; likewise for thinking. [status] is written
  /// into the tool JSON's `status` key, creating the object when the row had
  /// none. Null when there is no such row.
  SessionMessage? patch(
    String id, {
    String? text,
    String? appendText,
    String? thinking,
    String? appendThinking,
    String? toolJson,
    String? planJson,
    String? status,
    String? model,
  }) {
    return _db.transaction(() {
      final current = getById(id);
      if (current == null) return null;
      final revision = latestRevision(current.sessionId) + 1;
      var tool = toolJson ?? current.toolJson;
      if (status != null) {
        final decoded = tool == null ? null : jsonDecode(tool);
        final object = decoded is Map
            ? decoded.cast<String, Object?>()
            : <String, Object?>{};
        object['status'] = status;
        tool = jsonEncode(object);
      }
      var nextThinking = thinking ?? current.thinking;
      if (appendThinking != null) {
        nextThinking = (nextThinking ?? '') + appendThinking;
      }
      final next = current.copyWith(
        text: (text ?? current.text) + (appendText ?? ''),
        thinking: nextThinking,
        toolJson: tool,
        planJson: planJson ?? current.planJson,
        revision: revision,
        updatedAt: _now(),
        model: model,
      );
      _db.execute(
        'UPDATE session_messages SET text = ?, thinking = ?, tool_json = ?, '
        'plan_json = ?, revision = ?, updated_at = ?, model = ? WHERE id = ?;',
        [
          next.text,
          next.thinking,
          next.toolJson,
          next.planJson,
          next.revision,
          isoFromDate(next.updatedAt),
          next.model,
          id,
        ],
      );
      return next;
    });
  }

  SessionMessage? getById(String id) {
    final rows = _db.query('SELECT * FROM session_messages WHERE id = ?;', [
      id,
    ]);
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  /// The rows of [sessionId] after [afterOrdinal], in order; at most [limit]
  /// when given.
  List<SessionMessage> listAfter(
    String sessionId, {
    int afterOrdinal = -1,
    int? limit,
  }) {
    final rows = _db.query(
      'SELECT * FROM session_messages WHERE session_id = ? AND ordinal > ? '
      'ORDER BY ordinal${limit == null ? '' : ' LIMIT ?'};',
      [sessionId, afterOrdinal, ?limit],
    );
    return rows.map(_fromRow).toList();
  }

  /// The rows of [sessionId] that changed after [revision], in order.
  List<SessionMessage> listSince(String sessionId, int revision) {
    final rows = _db.query(
      'SELECT * FROM session_messages WHERE session_id = ? AND revision > ? '
      'ORDER BY ordinal;',
      [sessionId, revision],
    );
    return rows.map(_fromRow).toList();
  }

  /// The session's revision: 0 while it has no rows.
  int latestRevision(String sessionId) {
    final rows = _db.query(
      'SELECT COALESCE(MAX(revision), 0) AS revision FROM session_messages '
      'WHERE session_id = ?;',
      [sessionId],
    );
    return rows.first['revision']! as int;
  }

  int countForSession(String sessionId) {
    final rows = _db.query(
      'SELECT COUNT(*) AS n FROM session_messages WHERE session_id = ?;',
      [sessionId],
    );
    return rows.first['n']! as int;
  }

  void deleteForSession(String sessionId) {
    _db.execute('DELETE FROM session_messages WHERE session_id = ?;', [
      sessionId,
    ]);
  }

  SessionMessage _fromRow(Map<String, Object?> row) => SessionMessage(
    id: row['id']! as String,
    sessionId: row['session_id']! as String,
    ordinal: row['ordinal']! as int,
    role:
        SessionMessageRole.values.asNameMap()[row['role']] ??
        SessionMessageRole.agent,
    text: row['text'] as String? ?? '',
    thinking: row['thinking'] as String?,
    toolJson: row['tool_json'] as String?,
    planJson: row['plan_json'] as String?,
    messageId: row['message_id'] as String?,
    revision: row['revision']! as int,
    model: row['model'] as String?,
    createdAt: dateFromIso(row['created_at']),
    updatedAt: dateFromIso(row['updated_at']),
  );
}
