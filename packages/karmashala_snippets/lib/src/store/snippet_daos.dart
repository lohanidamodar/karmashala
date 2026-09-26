import 'dart:convert';

import 'package:karmashala_store/database.dart';

import '../command_snippet.dart';
import '../stored_preset.dart';

/// The `command_snippets` table. The server's alone.
class CommandSnippetDao {
  CommandSnippetDao(this._db);

  final AppDatabase _db;

  void insert(CommandSnippet snippet) => _db.execute(
    'INSERT INTO command_snippets '
    '(id, label, command, shell, submit, created_at, updated_at) '
    'VALUES (?, ?, ?, ?, ?, ?, ?);',
    [
      snippet.id,
      snippet.label,
      snippet.command,
      snippet.shellId,
      intFromBool(snippet.submit),
      isoFromDate(snippet.createdAt),
      isoFromDate(snippet.updatedAt),
    ],
  );

  void update(CommandSnippet snippet) => _db.execute(
    'UPDATE command_snippets SET label = ?, command = ?, shell = ?, '
    'submit = ?, updated_at = ? WHERE id = ?;',
    [
      snippet.label,
      snippet.command,
      snippet.shellId,
      intFromBool(snippet.submit),
      isoFromDate(snippet.updatedAt),
      snippet.id,
    ],
  );

  void delete(String id) =>
      _db.execute('DELETE FROM command_snippets WHERE id = ?;', [id]);

  /// Every snippet, oldest first ([compareSnippets]).
  List<CommandSnippet> list() => _db
      .query('SELECT * FROM command_snippets ORDER BY created_at, id;')
      .map(_fromRow)
      .toList();

  CommandSnippet? getById(String id) {
    final rows = _db.query('SELECT * FROM command_snippets WHERE id = ?;', [
      id,
    ]);
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  CommandSnippet _fromRow(Map<String, Object?> row) => CommandSnippet(
    id: row['id']! as String,
    label: row['label']! as String,
    command: row['command']! as String,
    shellId: row['shell'] as String?,
    submit: boolFromInt(row['submit']),
    createdAt: dateFromIso(row['created_at']),
    updatedAt: dateFromIso(row['updated_at']),
  );
}

/// The `terminal_presets` table. The server's alone; a shape is kept as the
/// client wrote it.
class TerminalPresetDao {
  TerminalPresetDao(this._db);

  final AppDatabase _db;

  /// Every preset, the one touched last first ([comparePresets]). A row whose
  /// shape is not JSON is skipped, so one bad preset cannot stop the list.
  List<StoredPreset> getAll() => _db
      .query(
        'SELECT id, name, shape, updated_at FROM terminal_presets '
        'ORDER BY updated_at DESC, name;',
      )
      .map(_preset)
      .nonNulls
      .toList();

  StoredPreset? byId(String id) => _db
      .query(
        'SELECT id, name, shape, updated_at FROM terminal_presets '
        'WHERE id = ?;',
        [id],
      )
      .map(_preset)
      .nonNulls
      .firstOrNull;

  /// Writes [preset] under its id, keeping when it was first saved.
  void save(StoredPreset preset) => _db.execute(
    'INSERT INTO terminal_presets (id, name, shape, created_at, updated_at) '
    'VALUES (?, ?, ?, ?, ?) '
    'ON CONFLICT(id) DO UPDATE SET name = excluded.name, '
    'shape = excluded.shape, updated_at = excluded.updated_at;',
    [
      preset.id,
      preset.name,
      jsonEncode(preset.shape),
      isoFromDate(preset.updatedAt),
      isoFromDate(preset.updatedAt),
    ],
  );

  void delete(String id) =>
      _db.execute('DELETE FROM terminal_presets WHERE id = ?;', [id]);

  static StoredPreset? _preset(Map<String, Object?> row) {
    final raw = row['shape'] as String?;
    if (raw == null || raw.isEmpty) return null;
    try {
      final shape = jsonDecode(raw);
      if (shape is! Map) return null;
      return StoredPreset(
        id: row['id']! as String,
        name: row['name']! as String,
        shape: shape.cast<String, Object?>(),
        updatedAt: dateFromIso(row['updated_at']),
      );
    } on FormatException {
      return null;
    }
  }
}
