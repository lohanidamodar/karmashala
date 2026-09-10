import 'package:riverpod/riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/database/database_providers.dart';
import '../domain/explorer_section.dart';

/// Data access for saved Explorer sections (schema v29). What is stored is the
/// *definition*, never a rule section's membership — a copy in SQLite would be
/// a second answer that disagrees with the live one.
class ExplorerSectionDao {
  ExplorerSectionDao(this._db);

  final AppDatabase _db;

  /// Every section, in sidebar order — which is also priority order. Two
  /// statements whatever the workspace holds; per-section it would be one a
  /// group, on every mutation of a list the user is looking at.
  List<ExplorerSection> getAll() {
    final members = <String, Set<String>>{};
    for (final row in _db.query(
      'SELECT section_id, session_id FROM explorer_section_members;',
    )) {
      (members[row['section_id']! as String] ??= <String>{}).add(
        row['session_id']! as String,
      );
    }

    final sections = <ExplorerSection>[];
    for (final row in _db.query(
      'SELECT id, name, kind, pattern, position, collapsed '
      'FROM explorer_sections ORDER BY position, id;',
    )) {
      final id = row['id']! as String;
      final rule = SectionRule.fromStorage(
        row['kind'] as String?,
        row['pattern'] as String?,
      );
      // A row whose `kind` this build does not know is skipped rather than
      // guessed at: that is a downgrade, and drawing it as a manual group would
      // strip the rule the moment the user renamed it.
      if (rule == null) continue;
      sections.add(
        ExplorerSection(
          id: id,
          name: row['name']! as String,
          rule: rule,
          position: row['position']! as int,
          collapsed: (row['collapsed']! as int) != 0,
          members: members[id] ?? const {},
        ),
      );
    }
    return sections;
  }

  /// Appends [section] at its own [ExplorerSection.position].
  void insert(ExplorerSection section) {
    _db.transaction(() {
      _db.execute(
        'INSERT INTO explorer_sections '
        '(id, name, kind, pattern, position, collapsed) '
        'VALUES (?, ?, ?, ?, ?, ?);',
        [
          section.id,
          section.name,
          section.rule.kind.name,
          section.rule.pattern,
          section.position,
          section.collapsed ? 1 : 0,
        ],
      );
      _writeMembers(section);
    });
  }

  /// Rewrites everything about [section] except its id.
  void update(ExplorerSection section) {
    _db.transaction(() {
      _db.execute(
        'UPDATE explorer_sections SET name = ?, kind = ?, pattern = ?, '
        'position = ?, collapsed = ? WHERE id = ?;',
        [
          section.name,
          section.rule.kind.name,
          section.rule.pattern,
          section.position,
          section.collapsed ? 1 : 0,
          section.id,
        ],
      );
      _db.execute(
        'DELETE FROM explorer_section_members WHERE section_id = ?;',
        [section.id],
      );
      _writeMembers(section);
    });
  }

  /// The one write a collapse toggle makes. Its own statement because folding a
  /// section shut is this table's most frequent write and must not rewrite a
  /// hand-filled group's whole member list to record one bit.
  void setCollapsed(String id, bool collapsed) => _db.execute(
    'UPDATE explorer_sections SET collapsed = ? WHERE id = ?;',
    [collapsed ? 1 : 0, id],
  );

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

  void addMember(String sectionId, String sessionId) => _db.execute(
    'INSERT OR IGNORE INTO explorer_section_members (section_id, session_id) '
    'VALUES (?, ?);',
    [sectionId, sessionId],
  );

  void removeMember(String sectionId, String sessionId) => _db.execute(
    'DELETE FROM explorer_section_members WHERE section_id = ? '
    'AND session_id = ?;',
    [sectionId, sessionId],
  );

  void _writeMembers(ExplorerSection section) {
    // Rules have no stored membership, and writing one would be the second
    // answer this table exists not to have.
    if (!section.rule.isManual) return;
    for (final sessionId in section.members) {
      _db.execute(
        'INSERT OR IGNORE INTO explorer_section_members '
        '(section_id, session_id) VALUES (?, ?);',
        [section.id, sessionId],
      );
    }
  }
}

final explorerSectionDaoProvider = Provider<ExplorerSectionDao>(
  (ref) => ExplorerSectionDao(ref.watch(databaseProvider)),
);
