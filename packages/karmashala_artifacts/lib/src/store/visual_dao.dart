import 'dart:convert';

import 'package:karmashala_store/database.dart';

import '../domain/session_visual.dart';

/// The `session_visuals` table.
class VisualDao {
  VisualDao(this._db);

  final AppDatabase _db;

  void save(SessionVisual v) => _db.execute(
    'INSERT INTO session_visuals (session_id, id, kind, title, spec, '
    'revision, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?) '
    'ON CONFLICT (session_id, id) DO UPDATE SET kind = excluded.kind, '
    'title = excluded.title, spec = excluded.spec, '
    'revision = excluded.revision, updated_at = excluded.updated_at;',
    [
      v.sessionId,
      v.id,
      v.kind,
      v.title,
      jsonEncode(v.data),
      v.revision,
      isoFromDate(v.createdAt),
      isoFromDate(v.updatedAt),
    ],
  );

  SessionVisual? byId(String sessionId, String id) {
    final rows = _db.query(
      'SELECT * FROM session_visuals WHERE session_id = ? AND id = ?;',
      [sessionId, id],
    );
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  /// [sessionId]'s visuals, in the order they were first drawn.
  List<SessionVisual> forSession(String sessionId) => [
    for (final row in _db.query(
      'SELECT * FROM session_visuals WHERE session_id = ? '
      'ORDER BY created_at, id;',
      [sessionId],
    ))
      _fromRow(row),
  ];

  int count(String sessionId) =>
      _db.query(
            'SELECT COUNT(*) AS n FROM session_visuals WHERE session_id = ?;',
            [sessionId],
          ).first['n']!
          as int;

  SessionVisual _fromRow(Map<String, Object?> row) => SessionVisual(
    sessionId: row['session_id']! as String,
    id: row['id']! as String,
    kind: row['kind']! as String,
    title: row['title'] as String?,
    data: jsonDecode(row['spec']! as String),
    revision: row['revision']! as int,
    createdAt: dateFromIso(row['created_at']),
    updatedAt: dateFromIso(row['updated_at']),
  );
}
