import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/database/migrations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

/// Applies every migration up to and including [upTo], the way `AppDatabase`
/// does, so a *pre-v21* database can be populated and then migrated.
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
  test('the head stays contiguous and is the migration count', () {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    expect(schemaMigrations.keys.toList()..sort(), [
      for (var v = 1; v <= schemaMigrations.length; v++) v,
    ]);
    expect(db.schemaVersion, schemaMigrations.length);
    expect(db.schemaVersion, 35);
  });

  test('v21 adds notes to an existing database without touching it', () {
    final db = _migratedTo(20);
    addTearDown(db.close);
    db.execute('PRAGMA foreign_keys = OFF;');
    db.execute(
      'INSERT INTO sessions (id, repository_id, agent_installation_id, title, '
      'use_worktree, status, created_at) '
      "VALUES ('s-1', 'r-1', 'i-1', 'Old session', 0, 'idle', "
      "'2026-08-01T00:00:00.000Z');",
    );
    expect(
      db.select("SELECT name FROM sqlite_master WHERE name = 'notes';").isEmpty,
      isTrue,
      reason: 'notes must not exist before its own migration',
    );

    schemaMigrations[21]!(db);

    // The upgrade adds a table and changes nothing that was there.
    expect(
      db.select('SELECT title FROM sessions;').single['title'],
      'Old session',
    );
    final columns = db
        .select('PRAGMA table_info(notes);')
        .map((r) => r['name'])
        .toList();
    expect(columns, [
      'id',
      'title',
      'body',
      'source_session_id',
      'source_repository_id',
      'source_message_ordinal',
      'source_message_role',
      'created_at',
      'updated_at',
    ]);
  });

  test('a note outlives the session it was taken from', () {
    // The reason `source_session_id` is not a foreign key: a note is a
    // deferred instruction, and deleting a finished session must not delete
    // the idea it produced.
    final db = _migratedTo(21);
    addTearDown(db.close);
    db.execute('PRAGMA foreign_keys = ON;');
    db.execute(
      'INSERT INTO execution_environments (id, kind, name, created_at) '
      "VALUES ('e-1', 'windowsNative', 'Windows', '2026-08-01');",
    );
    db.execute(
      'INSERT INTO projects (id, name, root_environment_id, root_path, '
      "created_at) VALUES ('p-1', 'Demo', 'e-1', 'C:/src', '2026-08-01');",
    );
    db.execute(
      'INSERT INTO repositories (id, project_id, name, environment_id, path, '
      "created_at) VALUES ('r-1', 'p-1', 'app', 'e-1', 'C:/src/app', "
      "'2026-08-01');",
    );
    db.execute(
      'INSERT INTO agent_installations (id, agent_kind, environment_id, '
      "executable_path, created_at) VALUES ('i-1', 'claude', 'e-1', "
      "'claude', '2026-08-01');",
    );
    db.execute(
      'INSERT INTO sessions (id, repository_id, agent_installation_id, title, '
      'use_worktree, status, created_at) '
      "VALUES ('s-1', 'r-1', 'i-1', 'Doomed', 0, 'idle', '2026-08-01');",
    );
    db.execute(
      'INSERT INTO notes (id, body, source_session_id, source_repository_id, '
      'source_message_ordinal, source_message_role, created_at, updated_at) '
      "VALUES ('n-1', 'ideate on the toolbar', 's-1', 'r-1', 3, 'agent', "
      "'2026-08-01', '2026-08-01');",
    );

    db.execute("DELETE FROM sessions WHERE id = 's-1';");

    final note = db.select('SELECT * FROM notes;').single;
    expect(note['body'], 'ideate on the toolbar');
    // The origin still says what it said; it simply no longer resolves.
    expect(note['source_session_id'], 's-1');
  });
}
