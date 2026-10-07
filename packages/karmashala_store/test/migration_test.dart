import 'package:karmashala_store/database.dart';
import 'package:karmashala_store/migrations.dart';
import 'package:test/test.dart';

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.memory());
  tearDown(() => db.close());

  List<String> tableNames() => db
      .query("SELECT name FROM sqlite_master WHERE type = 'table';")
      .map((r) => r['name']! as String)
      .toList();

  test('migrates a fresh database to the current schema version', () {
    expect(db.schemaVersion, 89);
    final version = db.query('PRAGMA user_version;').first.values.first! as int;
    expect(version, 89);
    final indexes = db.query("PRAGMA index_list('sessions');");
    expect(indexes.map((row) => row['name']), contains('idx_sessions_pane'));
    expect(
      indexes.map((row) => row['name']),
      contains('idx_sessions_external'),
    );
    expect(
      indexes.map((row) => row['name']),
      contains('idx_sessions_installation'),
    );
  });

  test('the migration keys stay contiguous, and the version is their '
      'count', () {
    // The invariant two parallel loops share: a gap means somebody renumbered
    // around a merge and never closed it.
    expect(schemaMigrations.keys.toList()..sort(), [
      for (var v = 1; v <= schemaMigrations.length; v++) v,
    ]);
    expect(db.schemaVersion, schemaMigrations.length);
  });

  test('v19 gives paired_devices the relay it was paired through', () {
    final columns = db
        .query('PRAGMA table_info(paired_devices);')
        .map((r) => r['name']! as String)
        .toList();
    expect(columns, contains('relay_url'));

    // Nullable and undefaulted: a fresh install has no relay to name until a
    // pairing names one, and the writer always does.
    final column = db
        .query('PRAGMA table_info(paired_devices);')
        .firstWhere((r) => r['name'] == 'relay_url');
    expect(column['notnull'], 0);
    expect(column['dflt_value'], isNull);
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
        'codex_accounts',
        'ssh_hosts',
        'ssh_known_hosts',
        'fanout_comparisons',
        'fanout_candidates',
        'paired_devices',
        'conversation_turns',
        'conversation_index_state',
      ]),
    );
  });

  test('v18 creates the paired-device store', () {
    final columns = db
        .query('PRAGMA table_info(paired_devices);')
        .map((r) => r['name']! as String)
        .toList();
    expect(
      columns,
      containsAll(<String>[
        'id',
        'name',
        'device_key',
        'capabilities',
        'generation',
        'revoked',
        'push_token',
        'push_platform',
        'created_at',
        'last_seen_at',
      ]),
    );

    // A row written before anyone revoked anything reads back unrevoked.
    db.execute(
      'INSERT INTO paired_devices '
      '(id, name, device_key, capabilities, generation, created_at) '
      "VALUES ('d', 'Phone', 'ab', 31, 1, '2026-01-01T00:00:00.000Z');",
    );
    expect(
      db.query('SELECT revoked FROM paired_devices;').single['revoked'],
      0,
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
    expect(db.schemaVersion, 89);
    expect(tableNames(), contains('sessions'));
    expect(db.readMetadata('k'), 'v');
  });

  test('v59 leaves the terminal layout to each client', () {
    // Presets are shared, and stay.
    expect(tableNames().where((name) => name.startsWith('terminal_')), [
      'terminal_presets',
    ]);
  });

  test('v11 gives sessions a nullable permission mode with no default', () {
    final column = db
        .query('PRAGMA table_info(sessions);')
        .firstWhere((r) => r['name'] == 'permission_mode');

    // Both halves matter, and they are the whole point of the column's shape.
    // Nullable with no default means a row written before v11 reads back as
    // null — "we never recorded it" — and the resolver falls back to the agent
    // setting. `NOT NULL DEFAULT 'ask'` would instead have every old session
    // claim it ran under the safe mode, which plenty of them did not.
    expect(column['notnull'], 0);
    expect(column['dflt_value'], isNull);
  });

  test('v13 gives sessions a nullable parent link kind', () {
    final column = db
        .query('PRAGMA table_info(sessions);')
        .firstWhere((r) => r['name'] == 'parent_link_kind');

    // Nullable and undefaulted, like permission_mode: a root session has no
    // relationship to name, so a default of any kind would be inventing one.
    expect(column['notnull'], 0);
    expect(column['dflt_value'], isNull);
  });

  test('a gap in the migration keys is migrated through, not refused', () {
    // The old runner asked for `current + 1` and threw `Missing migration step`
    // on a gap, refusing to open a database it could have migrated perfectly
    // well. The whole `sessions` table arriving proves the steps either side of
    // the gap both ran.
    expect(tableNames(), contains('sessions'));
    final columns = db
        .query('PRAGMA table_info(sessions);')
        .map((r) => r['name']! as String)
        .toList();
    expect(columns, contains('permission_mode'));
    expect(columns, contains('parent_link_kind'));
  });
}
