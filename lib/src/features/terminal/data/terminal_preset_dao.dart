import 'dart:convert';

import '../../../core/database/app_database.dart';
import '../../../core/database/row_mapping.dart';
import '../domain/terminal_preset.dart';

/// Data-access for the `terminal_presets` table (v44). Hand-written SQL, no
/// codegen, the same shape as `CommandSnippetDao`.
///
/// **A row, not a metadata key**, unlike the workspace tree beside it in
/// `TerminalLayoutDao`. That tree is *the* layout and there is one; presets are
/// a list the user names, adds to and deletes from, and a list that has to be
/// ordered and looked up by name is what a table is for.
class TerminalPresetDao {
  TerminalPresetDao(this._db);

  final AppDatabase _db;

  /// Every preset, newest name-change first — which is the order the user last
  /// touched them in, and the order a picker should offer.
  List<TerminalPreset> getAll() => _db
      .query(
        'SELECT id, name, shape FROM terminal_presets '
        'ORDER BY updated_at DESC, name;',
      )
      .map(_preset)
      .nonNulls
      .toList();

  TerminalPreset? byId(String id) => _db
      .query('SELECT id, name, shape FROM terminal_presets WHERE id = ?;', [id])
      .map(_preset)
      .nonNulls
      .firstOrNull;

  /// Writes [preset] under its id, replacing whatever was there.
  ///
  /// Upsert rather than insert-or-replace: re-saving a preset under the same
  /// name keeps its id, which is what anything referring to it holds.
  void save(TerminalPreset preset, DateTime now) {
    _db.execute(
      'INSERT INTO terminal_presets (id, name, shape, created_at, updated_at) '
      'VALUES (?, ?, ?, ?, ?) '
      'ON CONFLICT(id) DO UPDATE SET name = excluded.name, '
      'shape = excluded.shape, updated_at = excluded.updated_at;',
      [
        preset.id,
        preset.name,
        jsonEncode(preset.toJson()),
        isoFromDate(now),
        isoFromDate(now),
      ],
    );
  }

  void delete(String id) =>
      _db.execute('DELETE FROM terminal_presets WHERE id = ?;', [id]);

  /// Reading is deliberately forgiving: a row this code cannot parse is skipped
  /// rather than thrown on, so one bad preset cannot stop the list being read.
  static TerminalPreset? _preset(Map<String, Object?> row) {
    final raw = row['shape'] as String?;
    if (raw == null || raw.isEmpty) return null;
    try {
      return TerminalPreset.fromJson(
        id: row['id']! as String,
        name: row['name']! as String,
        shape: jsonDecode(raw),
      );
    } on FormatException {
      return null;
    }
  }
}
