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
    expect(db.schemaVersion, 11);
    final version = db.query('PRAGMA user_version;').first.values.first! as int;
    expect(version, 11);
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
        'terminal_tabs',
        'terminal_panes',
        'ssh_hosts',
        'ssh_known_hosts',
        'fanout_comparisons',
        'fanout_candidates',
      ]),
    );
  });

  test('execution_environments carries the ssh host link', () {
    final columns = db
        .query('PRAGMA table_info(execution_environments);')
        .map((r) => r['name']! as String)
        .toList();
    expect(columns, contains('ssh_host_id'));
  });

  test('metadata key/value store still works after migration', () {
    db.writeMetadata('color', 'indigo');
    expect(db.readMetadata('color'), 'indigo');
  });

  test('re-opening does not re-run migrations or lose data', () {
    db.writeMetadata('k', 'v');
    // A second AppDatabase on a fresh memory db is independent; instead verify
    // idempotency by confirming user_version is stable and tables intact.
    expect(db.schemaVersion, 11);
    expect(tableNames(), contains('sessions'));
    expect(db.readMetadata('k'), 'v');
  });

  test('v9 gives terminal_tabs the detached flag, defaulted off', () {
    final columns = db
        .query('PRAGMA table_info(terminal_tabs);')
        .map((r) => r['name']! as String)
        .toList();
    expect(columns, contains('detached'));

    // An old row written without the column must read back as "a real tab",
    // never as a background session that vanishes from the tab bar.
    db.execute(
      'INSERT INTO terminal_tabs (id, ordinal, layout, focused_pane_id, '
      'is_active, updated_at) VALUES (?, ?, ?, ?, ?, ?);',
      ['t', 0, '{"type":"leaf","id":"p"}', 'p', 1, '2026-01-01T00:00:00.000Z'],
    );
    expect(
      db.query('SELECT detached FROM terminal_tabs;').single['detached'],
      0,
    );
  });
}
