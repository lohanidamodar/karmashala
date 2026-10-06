import 'package:karmashala_store/migrations.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

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

/// v76 separates a removed worktree from an archived session: until now
/// `archived_at` meant both, and only "Archive worktree" set it.
void main() {
  test('v76 records when a worktree was removed, read from the archive the '
      'worktree action left', () {
    final db = _migratedTo(75);
    addTearDown(db.close);
    db.execute('PRAGMA foreign_keys = OFF;');
    const at = '2026-09-01T00:00:00.000Z';
    db.execute(
      'INSERT INTO sessions (id, repository_id, agent_installation_id, title, '
      'use_worktree, worktree_environment_id, worktree_path, status, '
      'created_at, archived_at) VALUES '
      "('tree', 'r', 'i', 'T', 1, 'windows', '/wt', 'completed', ?, ?),"
      "('root', 'r', 'i', 'R', 0, NULL, NULL, 'completed', ?, ?),"
      "('live', 'r', 'i', 'L', 1, 'windows', '/wt2', 'running', ?, NULL);",
      [at, at, at, at, at],
    );

    schemaMigrations[76]!(db);
    schemaMigrations[76]!(db);

    final rows = {
      for (final row in db.select(
        'SELECT id, archived_at, worktree_removed_at FROM sessions;',
      ))
        row['id'] as String: row,
    };
    expect(rows['tree']!['worktree_removed_at'], at);
    expect(rows['tree']!['archived_at'], at, reason: 'still archived');
    expect(rows['root']!['worktree_removed_at'], isNull);
    expect(rows['live']!['worktree_removed_at'], isNull);
  });
}
