import 'package:karmashala_store/migrations.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

/// Schema v21 (notes) and v34 (todos, and filing notes under a project):
/// what the tables are and what the foreign keys keep. Moved here from the
/// app, which no longer reaches these tables
/// (slice 1: data through the server).

/// Applies every migration up to and including [upTo], the way `AppDatabase`
/// does, so an older database can be populated and then migrated.
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

/// One project, and one repository in it.
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
  test('the migrations are numbered without a gap', () {
    expect(schemaMigrations.keys.toList()..sort(), [
      for (var v = 1; v <= schemaMigrations.length; v++) v,
    ]);
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

    expect(
      db.select('SELECT title FROM sessions;').single['title'],
      'Old session',
    );
    expect(db.select('PRAGMA table_info(notes);').map((r) => r['name']), [
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
    // `source_session_id` is not a foreign key: deleting a finished session
    // must not delete the idea it produced.
    final db = _migratedTo(21);
    addTearDown(db.close);
    db.execute('PRAGMA foreign_keys = ON;');
    _seedProject(db);
    db.execute(
      'INSERT INTO agent_installations (id, agent_kind, environment_id, '
      "executable_path, created_at) VALUES ('i-1', 'claude', 'e-1', "
      "'claude', '2026-08-01');",
    );
    db.execute(
      'INSERT INTO sessions (id, repository_id, agent_installation_id, title, '
      'use_worktree, status, created_at) '
      "VALUES ('s-1', 'r-p-1', 'i-1', 'Doomed', 0, 'idle', '2026-08-01');",
    );
    db.execute(
      'INSERT INTO notes (id, body, source_session_id, source_repository_id, '
      'source_message_ordinal, source_message_role, created_at, updated_at) '
      "VALUES ('n-1', 'ideate on the toolbar', 's-1', 'r-p-1', 3, 'agent', "
      "'2026-08-01', '2026-08-01');",
    );

    db.execute("DELETE FROM sessions WHERE id = 's-1';");

    final note = db.select('SELECT * FROM notes;').single;
    expect(note['body'], 'ideate on the toolbar');
    expect(note['source_session_id'], 's-1');
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
    );
    final note = db.select('SELECT * FROM notes;').single;
    expect(note['body'], 'no session, no repository');
    expect(note['project_id'], isNull);
    // Unfiled is the resting state, not a value somebody has to clear.
    for (final table in ['notes', 'todos']) {
      final column = db
          .select('PRAGMA table_info($table);')
          .firstWhere((r) => r['name'] == 'project_id');
      expect(column['notnull'], 0, reason: '$table.project_id is nullable');
      expect(column['dflt_value'], isNull);
    }
  });

  test('v34 files an existing note under its repository’s project', () {
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
    // Its repository is gone: nothing to file it under.
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
    // `ON DELETE SET NULL`, not `CASCADE`: the note saying what went wrong is
    // worth the most when the work is over.
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
      "VALUES ('t-1', 'write it up', 'p-1', 0, '2026-08-01T00:00:00.000Z');",
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
    final db = _migratedTo(34);
    addTearDown(db.close);
    db.execute('PRAGMA foreign_keys = ON;');
    expect(
      () => db.execute(
        'INSERT INTO todos (id, body, project_id, position, created_at) '
        "VALUES ('t-1', 'nowhere', 'p-ghost', 0, '2026-08-01T00:00:00.000Z');",
      ),
      throwsA(isA<SqliteException>()),
    );
  });
}
