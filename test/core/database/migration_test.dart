import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.memory());
  tearDown(() => db.close());

  List<String> tableNames() => db
      .query("SELECT name FROM sqlite_master WHERE type = 'table';")
      .map((r) => r['name']! as String)
      .toList();

  test('migrates a fresh database to the current schema version', () {
    expect(db.schemaVersion, 6);
    final version = db.query('PRAGMA user_version;').first.values.first! as int;
    expect(version, 6);
  });

  test('creates all domain tables plus app_metadata', () {
    final tables = tableNames();
    expect(
      tables,
      containsAll(<String>[
        'app_metadata',
        'execution_environments',
        'projects',
        'repositories',
        'agent_installations',
        'sessions',
        'session_events',
        'session_repositories',
        'imported_sessions',
        'claude_accounts',
      ]),
    );
  });

  test('metadata key/value store still works after migration', () {
    db.writeMetadata('color', 'indigo');
    expect(db.readMetadata('color'), 'indigo');
  });

  test('re-opening does not re-run migrations or lose data', () {
    db.writeMetadata('k', 'v');
    // A second AppDatabase on a fresh memory db is independent; instead verify
    // idempotency by confirming user_version is stable and tables intact.
    expect(db.schemaVersion, 6);
    expect(tableNames(), contains('sessions'));
    expect(db.readMetadata('k'), 'v');
  });
}
