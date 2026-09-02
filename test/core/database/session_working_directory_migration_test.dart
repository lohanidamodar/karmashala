import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/database/migrations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

/// Applies every migration up to and including [upTo], the way `AppDatabase`
/// does, so a *pre-v22* database can be populated and then migrated.
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
    expect(db.schemaVersion, 30);
  });

  test('v22 gives sessions a working directory bound to an environment', () {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final columns = db
        .query('PRAGMA table_info(sessions);')
        .where((r) => (r['name']! as String).startsWith('working_directory_'))
        .toList();

    // Two columns, exactly like `worktree_*`: a path is never stored divorced
    // from the environment that gives it meaning, so a WSL session's cwd reads
    // back as a WSL path in the WSL environment.
    expect(columns.map((r) => r['name']).toList(), [
      'working_directory_environment_id',
      'working_directory_path',
    ]);

    // Nullable and undefaulted, like `permission_mode`: a row written before
    // v22 never recorded where it ran, and null says exactly that. Defaulting
    // to the repository root would claim a directory those sessions may well
    // not have been started in — which is the lie this column exists to remove.
    for (final column in columns) {
      expect(column['notnull'], 0);
      expect(column['dflt_value'], isNull);
    }
  });

  test('v22 adds the columns to a populated database without touching it', () {
    final db = _migratedTo(21);
    addTearDown(db.close);
    db.execute('PRAGMA foreign_keys = OFF;');
    db.execute(
      'INSERT INTO sessions (id, repository_id, agent_installation_id, title, '
      'use_worktree, worktree_environment_id, worktree_path, status, '
      'created_at, external_session_id, pane_id, surface, view, '
      'permission_mode) '
      "VALUES ('s-1', 'r-1', 'i-1', 'Old session', 1, 'windows', "
      r"'C:\wt\s-1', 'running', '2026-08-01T00:00:00.000Z', 'ext-1', 'p-1', "
      "'pane', 'chat', 'ask');",
    );
    db.execute(
      'INSERT INTO sessions (id, repository_id, agent_installation_id, title, '
      'use_worktree, status, created_at) '
      "VALUES ('s-2', 'r-1', 'i-1', 'Plain session', 0, 'idle', "
      "'2026-08-02T00:00:00.000Z');",
    );

    schemaMigrations[22]!(db);

    final rows = db.select('SELECT * FROM sessions ORDER BY id;');
    expect(rows.length, 2);

    // Every pre-existing value survives, including the worktree the new column
    // must never be confused with.
    expect(rows[0]['title'], 'Old session');
    expect(rows[0]['use_worktree'], 1);
    expect(rows[0]['worktree_environment_id'], 'windows');
    expect(rows[0]['worktree_path'], r'C:\wt\s-1');
    expect(rows[0]['external_session_id'], 'ext-1');
    expect(rows[0]['pane_id'], 'p-1');
    expect(rows[0]['permission_mode'], 'ask');
    expect(rows[1]['title'], 'Plain session');
    expect(rows[1]['status'], 'idle');

    // And both rows read back as "we never recorded it" — not as the repository
    // root, and emphatically not as the worktree.
    for (final row in rows) {
      expect(row['working_directory_environment_id'], isNull);
      expect(row['working_directory_path'], isNull);
    }
  });
}
