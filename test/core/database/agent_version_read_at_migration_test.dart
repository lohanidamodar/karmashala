import 'package:karmashala/src/core/database/migrations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

/// Applies every migration up to and including [upTo], so a *pre-v40* database
/// can be populated and then migrated.
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
  test('v40 dates a version reading and leaves old rows undated', () {
    final db = _migratedTo(39);
    addTearDown(db.close);
    db.execute(
      "INSERT INTO execution_environments (id, kind, name, created_at) "
      "VALUES ('windows', 'windowsNative', 'Windows', '2026-01-01T00:00:00Z');",
    );
    db.execute(
      'INSERT INTO agent_installations '
      '(id, agent_kind, environment_id, executable_path, version, created_at) '
      "VALUES ('a1', 'claudeCode', 'windows', 'C:\\claude.exe', '2.1.245', "
      "'2026-01-01T00:00:00Z');",
    );

    schemaMigrations[40]!(db);

    // The number survives; its age does not get invented from `created_at`.
    // An unknown reading time is not a reading time (CLAUDE.md §19).
    final row = db.select('SELECT * FROM agent_installations;').single;
    expect(row['version'], '2.1.245');
    expect(row['version_read_at'], isNull);
  });

  test('v40 is idempotent, the way every step here has to be', () {
    final db = _migratedTo(39);
    addTearDown(db.close);

    schemaMigrations[40]!(db);
    schemaMigrations[40]!(db);

    final columns = db
        .select('PRAGMA table_info(agent_installations);')
        .map((row) => row['name'] as String);
    expect(columns.where((c) => c == 'version_read_at'), hasLength(1));
  });
}
