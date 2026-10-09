import 'package:karmashala_store/database.dart';
import 'package:karmashala_store/migrations.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

/// Applies every migration up to and including [upTo], the way `AppDatabase`
/// does, so a *pre-v31* database can be populated and then migrated.
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

/// A v30 database shaped like the owner's: several projects, repositories and
/// sessions already in it, and no idea that contexts exist.
Database _populatedV30() {
  final db = _migratedTo(30);
  db.execute('PRAGMA foreign_keys = ON;');
  db.execute(
    "INSERT INTO execution_environments (id, kind, name, created_at) "
    "VALUES ('windows', 'windowsNative', 'Windows', "
    "'2026-08-01T00:00:00.000Z');",
  );
  db.execute(
    'INSERT INTO agent_installations '
    '(id, agent_kind, environment_id, executable_path, created_at) '
    "VALUES ('i-1', 'claude-code', 'windows', 'claude.exe', "
    "'2026-08-01T00:00:00.000Z');",
  );
  for (var i = 0; i < 3; i++) {
    db.execute(
      'INSERT INTO projects '
      '(id, name, root_environment_id, root_path, created_at) '
      "VALUES ('p-$i', 'Project $i', 'windows', 'C:\\src\\p$i', "
      "'2026-08-01T00:00:00.000Z');",
    );
    db.execute(
      'INSERT INTO repositories '
      '(id, project_id, name, environment_id, path, created_at) '
      "VALUES ('r-$i', 'p-$i', 'app', 'windows', 'C:\\src\\p$i\\app', "
      "'2026-08-01T00:00:00.000Z');",
    );
    db.execute(
      'INSERT INTO sessions (id, repository_id, agent_installation_id, title, '
      'use_worktree, status, created_at) '
      "VALUES ('s-$i', 'r-$i', 'i-1', 'Work $i', 0, 'idle', "
      "'2026-08-01T00:00:00.000Z');",
    );
  }
  return db;
}

void main() {
  test('v39 is the head and the keys stay contiguous', () {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    expect(db.schemaVersion, 91);
    expect(schemaMigrations.keys.toList()..sort(), [
      for (var v = 1; v <= schemaMigrations.length; v++) v,
    ]);
  });

  test('an existing database upgrades with every project unassigned', () {
    // The one thing this migration owes the owner's live database: 31 projects
    // and thousands of sessions come out the other side, and none of them has
    // been filed anywhere by guesswork.
    final db = _populatedV30();
    addTearDown(db.close);

    schemaMigrations[31]!(db);

    final projects = db.select('SELECT * FROM projects ORDER BY id;');
    expect(projects.length, 3, reason: 'no project was lost');
    for (final row in projects) {
      expect(row['workspace_id'], isNull);
    }
    expect(db.select('SELECT * FROM repositories;').length, 3);
    expect(db.select('SELECT * FROM sessions;').length, 3);
    expect(db.select('SELECT * FROM workspaces;'), isEmpty);
  });

  test('the column is nullable and the table is what the picker needs', () {
    final db = AppDatabase.memory();
    addTearDown(db.close);

    final projectColumns = {
      for (final row in db.query('PRAGMA table_info(projects);'))
        row['name']! as String: row,
    };
    expect(projectColumns.keys, contains('workspace_id'));
    expect(
      projectColumns['workspace_id']!['notnull'],
      0,
      reason: 'unassigned is a normal state, not a hole to fill',
    );

    final workspaceColumns = {
      for (final row in db.query('PRAGMA table_info(workspaces);'))
        row['name']! as String: row,
    };
    expect(workspaceColumns.keys, {
      'id',
      'name',
      'description',
      'color',
      'created_at',
    });
    for (final required in const ['name', 'created_at']) {
      expect(workspaceColumns[required]!['notnull'], 1, reason: required);
    }
    expect(
      workspaceColumns['description']!['notnull'],
      0,
      reason: 'a context nobody has described is complete, not half-filled-in',
    );
  });

  test('v32 adds the description to an existing database, empty', () {
    // The v32 half of the same promise v31 made: the owner's contexts and the
    // projects filed under them come out the other side untouched, and the
    // column arrives holding the only thing the migration knows — nothing.
    final db = _populatedV30();
    addTearDown(db.close);
    schemaMigrations[31]!(db);
    db.execute(
      "INSERT INTO workspaces (id, name, created_at) "
      "VALUES ('w1', 'PopupBits', '2026-09-01T00:00:00.000Z');",
    );
    db.execute("UPDATE projects SET workspace_id = 'w1' WHERE id = 'p-0';");

    schemaMigrations[32]!(db);

    final workspaces = db.select('SELECT * FROM workspaces;');
    expect(workspaces.length, 1);
    expect(workspaces.first['name'], 'PopupBits');
    expect(workspaces.first['description'], isNull);
    expect(
      db
          .select("SELECT workspace_id FROM projects WHERE id = 'p-0';")
          .single['workspace_id'],
      'w1',
      reason: 'the grouping survives the upgrade',
    );
    expect(db.select('SELECT * FROM projects;').length, 3);
  });

  test('two contexts cannot share a name, whatever the case', () {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    void add(String id, String name) => db.execute(
      'INSERT INTO workspaces (id, name, created_at) VALUES (?, ?, ?);',
      [id, name, '2026-09-01T00:00:00.000Z'],
    );

    add('w1', 'Personal');
    expect(() => add('w2', 'personal'), throwsA(isA<SqliteException>()));
    add('w3', 'PopupBits');
    expect(db.query('SELECT * FROM workspaces;').length, 2);
  });

  test('deleting a context keeps its projects and unassigns them', () {
    // The single worst thing this table could do is cascade. Pinned here at
    // the schema level, because a controller can be rewritten and a foreign
    // key cannot be rewritten by accident.
    final db = AppDatabase.memory();
    addTearDown(db.close);
    db.execute('PRAGMA foreign_keys = ON;');
    db.execute(
      "INSERT INTO execution_environments (id, kind, name, created_at) "
      "VALUES ('windows', 'windowsNative', 'Windows', "
      "'2026-08-01T00:00:00.000Z');",
    );
    db.execute(
      "INSERT INTO workspaces (id, name, created_at) "
      "VALUES ('w1', 'Game dev', '2026-09-01T00:00:00.000Z');",
    );
    db.execute(
      'INSERT INTO projects '
      '(id, name, root_environment_id, root_path, created_at, workspace_id) '
      "VALUES ('p1', 'Roguelike', 'windows', 'C:\\games\\rl', "
      "'2026-08-01T00:00:00.000Z', 'w1');",
    );

    db.execute("DELETE FROM workspaces WHERE id = 'w1';");

    final rows = db.query('SELECT * FROM projects;');
    expect(rows.length, 1, reason: 'the project survives its context');
    expect(rows.first['workspace_id'], isNull);
  });

  test('a project cannot be filed under a context that is not there', () {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    db.execute('PRAGMA foreign_keys = ON;');
    db.execute(
      "INSERT INTO execution_environments (id, kind, name, created_at) "
      "VALUES ('windows', 'windowsNative', 'Windows', "
      "'2026-08-01T00:00:00.000Z');",
    );
    expect(
      () => db.execute(
        'INSERT INTO projects '
        '(id, name, root_environment_id, root_path, created_at, workspace_id) '
        "VALUES ('p1', 'Ghost', 'windows', 'C:\\src\\g', "
        "'2026-08-01T00:00:00.000Z', 'nope');",
      ),
      throwsA(isA<SqliteException>()),
    );
  });
}
