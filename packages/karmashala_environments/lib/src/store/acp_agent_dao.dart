import 'dart:convert';

import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_store/database.dart';

/// Data-access for [AcpAgentRow]s — the `acp_agents` table. Hand-written SQL;
/// `args` and `env` are JSON text.
class AcpAgentDao {
  AcpAgentDao(this._db);

  final AppDatabase _db;

  /// Writes [row] under its id, replacing what was there.
  void upsert(AcpAgentRow row) {
    _db.execute(
      'INSERT INTO acp_agents '
      '(id, name, command, args, env, source, registry_id, icon_url, '
      'created_at, mode_rungs) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(id) DO UPDATE SET name = excluded.name, '
      'command = excluded.command, args = excluded.args, env = excluded.env, '
      'source = excluded.source, registry_id = excluded.registry_id, '
      'icon_url = excluded.icon_url, created_at = excluded.created_at, '
      'mode_rungs = excluded.mode_rungs;',
      [
        row.id,
        row.name,
        row.command,
        jsonEncode(row.args),
        jsonEncode(row.env),
        row.source.name,
        row.registryId,
        row.iconUrl,
        isoFromDate(row.createdAt),
        jsonEncode({
          for (final e in row.modeRungs.entries) e.key: e.value.name,
        }),
      ],
    );
  }

  AcpAgentRow? getById(String id) {
    final rows = _db.query('SELECT * FROM acp_agents WHERE id = ?;', [id]);
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  /// Every row, oldest first.
  List<AcpAgentRow> getAll() => _db
      .query('SELECT * FROM acp_agents ORDER BY created_at, id;')
      .map(_fromRow)
      .toList();

  void delete(String id) {
    _db.execute('DELETE FROM acp_agents WHERE id = ?;', [id]);
  }

  AcpAgentRow _fromRow(Map<String, Object?> row) => AcpAgentRow(
    id: row['id']! as String,
    name: row['name']! as String,
    command: row['command']! as String,
    args: stringListFromJson(row['args']),
    env: stringMapFromJson(row['env']),
    // A source this build has no name for reads as typed in, like bad JSON.
    source:
        AcpAgentSource.values.asNameMap()[row['source']] ??
        AcpAgentSource.custom,
    registryId: row['registry_id'] as String?,
    iconUrl: row['icon_url'] as String?,
    createdAt: dateFromIso(row['created_at']),
    // A rung this build has no name for is dropped, like bad JSON.
    modeRungs: {
      for (final e in stringMapFromJson(row['mode_rungs']).entries)
        e.key: ?PermissionRisk.values.asNameMap()[e.value],
    },
  );
}

/// A JSON list of strings as the store keeps one; null, unparseable or out of
/// shape reads as none, so one bad row never takes the table down with it.
List<String> stringListFromJson(Object? json) {
  final decoded = _decode(json);
  if (decoded is! List) return const [];
  return List.unmodifiable(decoded.whereType<String>());
}

/// A JSON object of strings as the store keeps one; see [stringListFromJson].
Map<String, String> stringMapFromJson(Object? json) {
  final decoded = _decode(json);
  if (decoded is! Map) return const {};
  return Map.unmodifiable({
    for (final entry in decoded.entries)
      if (entry.key is String && entry.value is String)
        entry.key as String: entry.value as String,
  });
}

Object? _decode(Object? json) {
  if (json is! String || json.isEmpty) return null;
  try {
    return jsonDecode(json);
  } on FormatException {
    return null;
  }
}
