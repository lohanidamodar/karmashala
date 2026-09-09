import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/database/migrations.dart';
import 'package:sqlite3/sqlite3.dart';

/// Applies every migration up to and including [upTo], the way `AppDatabase`
/// does, so a *pre-v34* database can be populated and then migrated.
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

/// The rows every case here needs: one project, one repository in it, one
/// session in that repository, and the agent installation the session needs.
void _seedProject(Database db, {String project = 'p-1'}) {
  db.execute(
    'INSERT OR IGNORE INTO execution_environments (id, kind, name, created_at) '
    "VALUES ('e-1', 'windowsNative', 'Windows', '2026-08-01T00:00:00.000Z');",
  );
  db.execute(
    'INSERT INTO projects (id, name, root_environment_id, root_path, '
    "created_at) VALUES ('$project', '$project', 'e-1', 'C:/src/$project', "
    "'2026-08-01T00:00:00.000Z');",
  );
  db.execute(
    'INSERT INTO repositories (id, project_id, name, environment_id, path, '
    "created_at) VALUES ('r-$project', '$project', 'app', 'e-1', "
    "'C:/src/$project/app', '2026-08-01T00:00:00.000Z');",
  );
}

void main() {
  test('the head stays contiguous and is the migration count', () {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    expect(schemaMigrations.keys.toList()..sort(), [
      for (var v = 1; v <= schemaMigrations.length; v++) v,
    ]);
    expect(db.schemaVersion, schemaMigrations.length);
    expect(db.schemaVersion, 47);
  });

  test('v34 adds todos and the notes filing, and touches nothing else', () {
    final db = _migratedTo(32);
    addTearDown(db.close);
    _seedProject(db);
    db.execute(
      'INSERT INTO notes (id, body, created_at, updated_at) '
      "VALUES ('n-loose', 'no session, no repository', "
      "'2026-08-01T00:00:00.000Z', '2026-08-01T00:00:00.000Z');",
    );
    expect(
      db.select("SELECT name FROM sqlite_master WHERE name = 'todos';").isEmpty,
      isTrue,
      reason: 'todos must not exist before its own migration',
    );

    schemaMigrations[34]!(db);

    expect(
      db.select('PRAGMA table_info(todos);').map((r) => r['name']).toList(),
      ['id', 'body', 'done_at', 'project_id', 'position', 'created_at'],
      reason: 'six columns, and the migration says why each one is not five',
    );
    // The note that was there is still there, and unfiled — it never named a
    // repository, so there was nothing to file it under.
    final note = db.select('SELECT * FROM notes;').single;
    expect(note['body'], 'no session, no repository');
    expect(note['project_id'], isNull);
    // `project_id` is nullable on both tables and has no default: unfiled is
    // the resting state, not a value somebody has to clear.
    for (final table in ['notes', 'todos']) {
      final column = db
          .select('PRAGMA table_info($table);')
          .firstWhere((r) => r['name'] == 'project_id');
      expect(column['notnull'], 0, reason: '$table.project_id must be nullable');
      expect(column['dflt_value'], isNull);
    }
  });

  test('v34 files an existing note under its repository’s project', () {
    // The backfill. A note captured from a session already recorded that
    // session's repository, and a repository belongs to exactly one project —
    // so this is a lookup the database can already do, not a guess.
    final db = _migratedTo(32);
    addTearDown(db.close);
    _seedProject(db);
    _seedProject(db, project: 'p-2');
    db.execute(
      'INSERT INTO notes (id, body, source_session_id, source_repository_id, '
      "created_at, updated_at) VALUES ('n-1', 'about the toolbar', 's-1', "
      "'r-p-1', '2026-08-01T00:00:00.000Z', '2026-08-01T00:00:00.000Z');",
    );
    db.execute(
      'INSERT INTO notes (id, body, source_repository_id, created_at, '
      "updated_at) VALUES ('n-2', 'about the other one', 'r-p-2', "
      "'2026-08-01T00:00:00.000Z', '2026-08-01T00:00:00.000Z');",
    );
    // A note whose repository has since been deleted: the origin no longer
    // resolves, so there is nothing to file it under and it stays unfiled.
    db.execute(
      'INSERT INTO notes (id, body, source_repository_id, created_at, '
      "updated_at) VALUES ('n-3', 'orphan', 'r-gone', "
      "'2026-08-01T00:00:00.000Z', '2026-08-01T00:00:00.000Z');",
    );

    schemaMigrations[34]!(db);

    final filed = {
      for (final row in db.select('SELECT id, project_id FROM notes;'))
        row['id']: row['project_id'],
    };
    expect(filed, {'n-1': 'p-1', 'n-2': 'p-2', 'n-3': null});
  });

  test('deleting a project unfiles its notes and todos, and keeps them', () {
    // `ON DELETE SET NULL`, not `CASCADE`. A project is deleted when the work
    // is over, and that is exactly when the note saying what went wrong is
    // worth the most.
    final db = _migratedTo(34);
    addTearDown(db.close);
    db.execute('PRAGMA foreign_keys = ON;');
    _seedProject(db);
    db.execute(
      'INSERT INTO notes (id, body, project_id, created_at, updated_at) '
      "VALUES ('n-1', 'what went wrong', 'p-1', "
      "'2026-08-01T00:00:00.000Z', '2026-08-01T00:00:00.000Z');",
    );
    db.execute(
      'INSERT INTO todos (id, body, project_id, position, created_at) '
      "VALUES ('t-1', 'write it up', 'p-1', 0, "
      "'2026-08-01T00:00:00.000Z');",
    );

    db.execute("DELETE FROM projects WHERE id = 'p-1';");

    final note = db.select('SELECT * FROM notes;').single;
    expect(note['body'], 'what went wrong');
    expect(note['project_id'], isNull);
    final todo = db.select('SELECT * FROM todos;').single;
    expect(todo['body'], 'write it up');
    expect(todo['project_id'], isNull);
  });

  test('a todo cannot name a project that does not exist', () {
    // The other half of the foreign key. Filing is a claim about a row this
    // app owns, unlike `source_session_id`, which may name an imported
    // session that was never a row of ours.
    final db = _migratedTo(34);
    addTearDown(db.close);
    db.execute('PRAGMA foreign_keys = ON;');
    expect(
      () => db.execute(
        'INSERT INTO todos (id, body, project_id, position, created_at) '
        "VALUES ('t-1', 'nowhere', 'p-ghost', 0, "
        "'2026-08-01T00:00:00.000Z');",
      ),
      throwsA(isA<SqliteException>()),
    );
  });
}
