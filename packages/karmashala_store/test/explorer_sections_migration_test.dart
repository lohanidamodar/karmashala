import 'package:karmashala_store/migrations.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

/// Applies every migration up to and including [upTo], the way `AppDatabase`
/// does, so a *pre-v29* database can be populated and then migrated — the same
/// helper `notes_migration_test.dart` uses, for the same reason.
Database _migratedTo(int upTo) {
  final db = sqlite3.openInMemory();
  final versions = schemaMigrations.keys.where((v) => v <= upTo).toList()
    ..sort();
  for (final version in versions) {
    schemaMigrations[version]!(db);
    db.execute('PRAGMA user_version = $version;');
  }
  return db;
}

void main() {
  group('v29', () {
    test('seeds Pinned and three suggestions, all folded shut', () {
      final db = _migratedTo(29);
      addTearDown(db.close);
      final rows = db.select(
        'SELECT * FROM explorer_sections ORDER BY position;',
      );

      expect(
        [for (final r in rows) r['name']],
        ['Pinned', 'Checks failing', 'Awaiting input', 'Ended in failure'],
        reason:
            'the seeded order is the severity order a fixed priority table '
            'would have imposed — expressed as something the user can drag',
      );
      // The app reads each kind as its rule (app/test/features/explorer/
      // explorer_section_stored_test.dart).
      expect(
        [for (final r in rows) r['kind']],
        ['pinned', 'checksFailing', 'awaitingInput', 'endedInFailure'],
      );
      expect(rows.first['id'], 'section-pinned');
      expect(
        [for (final r in rows) r['collapsed']],
        everyElement(1),
        reason:
            'a workspace that upgrades into this feature and never opens a '
            'section must pay nothing for it',
      );
      expect([for (final r in rows) r['position']], [0, 1, 2, 3]);
    });

    test('adds its tables to an existing database without touching it', () {
      final db = _migratedTo(28);
      addTearDown(db.close);
      db.execute('PRAGMA foreign_keys = OFF;');
      db.execute(
        'INSERT INTO sessions (id, repository_id, agent_installation_id, '
        'title, use_worktree, status, created_at) '
        "VALUES ('s-1', 'r-1', 'i-1', 'Old session', 0, 'failed', "
        "'2026-08-01T00:00:00.000Z');",
      );

      schemaMigrations[29]!(db);
      db.execute('PRAGMA user_version = 29;');

      expect(
        db
            .select("SELECT title FROM sessions WHERE id = 's-1';")
            .single['title'],
        'Old session',
      );
      // The session predates the feature and already says `failed`. It is
      // **not** enrolled anywhere by the migration: the seeded groups are rule
      // sections, so what is in them is decided live and never written down.
      expect(db.select('SELECT * FROM explorer_section_members;'), isEmpty);
      expect(db.select('SELECT * FROM explorer_sections;').length, 4);
    });

    test('re-running the step is safe', () {
      final db = _migratedTo(29);
      addTearDown(db.close);
      schemaMigrations[29]!(db);
      expect(db.select('SELECT * FROM explorer_sections;').length, 4);
    });
  });
}
