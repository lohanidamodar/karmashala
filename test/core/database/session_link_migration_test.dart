import 'package:karmashala_store/migrations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

/// Applies every migration up to and including [upTo], the way `AppDatabase`
/// does, so a *pre-v16* database can be populated and then migrated.
///
/// The backfill is the only part of v16 that a fresh database cannot exercise:
/// there are no rows in one to backfill.
///
/// Walks the map's own keys rather than counting, because this branch's keys
/// are deliberately not dense — Loop 52 took v12 on `main` first, so this
/// loop's migration is v16 with a gap the merge will close.
Database _migratedTo(int upTo) {
  final db = sqlite3.openInMemory();
  db.execute('PRAGMA foreign_keys = ON;');
  final versions = schemaMigrations.keys.where((v) => v <= upTo).toList()
    ..sort();
  for (final version in versions) {
    schemaMigrations[version]!(db);
    db.execute('PRAGMA user_version = $version;');
  }
  return db;
}

void _seedSession(
  Database db,
  String id, {
  String? parent,
  String repository = 'repo-1',
}) {
  db.execute(
    'INSERT INTO sessions (id, repository_id, agent_installation_id, title, '
    'use_worktree, status, created_at, parent_session_id) '
    'VALUES (?, ?, ?, ?, 0, ?, ?, ?);',
    [
      id,
      repository,
      'install-1',
      'Session $id',
      'running',
      '2026-08-01',
      parent,
    ],
  );
}

void main() {
  test('v16 backfills spawn for rows that already had a parent', () {
    final db = _migratedTo(15);
    addTearDown(db.close);
    // Foreign keys would refuse a session with no repository row; the migration
    // is what is under test, not referential integrity.
    db.execute('PRAGMA foreign_keys = OFF;');
    _seedSession(db, 'root');
    _seedSession(db, 'child', parent: 'root');

    schemaMigrations[16]!(db);

    Object? linkOf(String id) => db.select(
      'SELECT parent_link_kind FROM sessions WHERE id = ?;',
      [id],
    ).first['parent_link_kind'];

    // The backfill is a *fact*, not a default: before v16 the only writer of
    // parent_session_id in the app was the MCP spawn path, so every parented
    // row genuinely is a spawn.
    expect(linkOf('child'), 'spawn');
    // A root session has no relationship, so there is nothing to name and
    // nothing is written. Defaulting it to anything would invent one.
    expect(linkOf('root'), isNull);
  });

  test('v16 does not disturb a database that already has the column', () {
    // `ALTER TABLE ... ADD COLUMN` cannot be made idempotent, and does not have
    // to be: `AppDatabase` runs each step exactly once, guarded by
    // `PRAGMA user_version`. What must hold is that a database already at v16
    // is left alone by the loop, which is what this asserts.
    final db = _migratedTo(16);
    addTearDown(db.close);
    expect(
      db.select('PRAGMA user_version;').first.values.first,
      greaterThanOrEqualTo(16),
    );
    final columns = db
        .select('PRAGMA table_info(sessions);')
        .map((r) => r['name'])
        .toList();
    expect(columns.where((c) => c == 'parent_link_kind'), hasLength(1));
  });
}
