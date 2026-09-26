import 'package:karmashala_store/database.dart';

import '../domain/stored_section.dart';

/// The saved Explorer sections (schema v29). What is stored is the
/// *definition*, never a rule section's membership — a copy in SQLite would be
/// a second answer that disagrees with the live one.
class SectionDao {
  SectionDao(this._db);

  final AppDatabase _db;

  /// Every section, in sidebar order. Two statements whatever the workspace
  /// holds.
  List<StoredSection> getAll() {
    final members = <String, Set<String>>{};
    for (final row in _db.query(
      'SELECT section_id, session_id FROM explorer_section_members;',
    )) {
      (members[row['section_id']! as String] ??= <String>{}).add(
        row['session_id']! as String,
      );
    }
    return [
      for (final row in _db.query(
        'SELECT id, name, kind, pattern, position, collapsed '
        'FROM explorer_sections ORDER BY position, id;',
      ))
        StoredSection(
          id: row['id']! as String,
          name: row['name']! as String,
          kind: row['kind']! as String,
          pattern: row['pattern'] as String?,
          position: row['position']! as int,
          collapsed: (row['collapsed']! as int) != 0,
          members: members[row['id']! as String] ?? const {},
        ),
    ];
  }

  StoredSection? getById(String id) {
    for (final section in getAll()) {
      if (section.id == id) return section;
    }
    return null;
  }

  /// Writes [section] whole — inserted, or everything but its id rewritten —
  /// in one transaction with its members. Only a manual section keeps any.
  void put(StoredSection section) {
    _db.transaction(() {
      _db.execute(
        'INSERT INTO explorer_sections '
        '(id, name, kind, pattern, position, collapsed) '
        'VALUES (?, ?, ?, ?, ?, ?) '
        'ON CONFLICT(id) DO UPDATE SET name = excluded.name, '
        'kind = excluded.kind, pattern = excluded.pattern, '
        'position = excluded.position, collapsed = excluded.collapsed;',
        [
          section.id,
          section.name,
          section.kind,
          section.pattern,
          section.position,
          section.collapsed ? 1 : 0,
        ],
      );
      _db.execute(
        'DELETE FROM explorer_section_members WHERE section_id = ?;',
        [section.id],
      );
      if (section.kind != StoredSection.manualKind) return;
      for (final sessionId in section.members) {
        _db.execute(
          'INSERT OR IGNORE INTO explorer_section_members '
          '(section_id, session_id) VALUES (?, ?);',
          [section.id, sessionId],
        );
      }
    });
  }

  /// Renumbers the sections to the order [ids] gives, in one transaction.
  /// Unknown ids are ignored and unnamed sections keep their position, so a
  /// reorder racing a delete renumbers what is there rather than throwing.
  void reorder(List<String> ids) {
    _db.transaction(() {
      for (var i = 0; i < ids.length; i++) {
        _db.execute('UPDATE explorer_sections SET position = ? WHERE id = ?;', [
          i,
          ids[i],
        ]);
      }
    });
  }

  /// Removes a section. Its members go with it via `ON DELETE CASCADE`.
  void delete(String id) =>
      _db.execute('DELETE FROM explorer_sections WHERE id = ?;', [id]);
}
