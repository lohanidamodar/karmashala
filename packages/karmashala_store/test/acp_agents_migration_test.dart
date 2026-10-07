import 'package:karmashala_store/database.dart';
import 'package:karmashala_store/migrations.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

/// v66: `agent_installations.leading_arguments`, what an `npx` installation
/// is run with; v67: `acp_agents`, the ACP agents a person added; v68:
/// `acp_agents.icon_url`, the registry's icon for the row.
void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.memory());
  tearDown(() => db.close());

  List<String> columnsOf(String table) => db
      .query('PRAGMA table_info($table);')
      .map((r) => r['name']! as String)
      .toList();

  test('the head is 88 and the keys stay contiguous', () {
    expect(schemaMigrations.keys.toList()..sort(), [
      for (var v = 1; v <= schemaMigrations.length; v++) v,
    ]);
    expect(db.schemaVersion, 88);
  });

  test('v66 adds leading_arguments, null for every row written before', () {
    expect(columnsOf('agent_installations'), contains('leading_arguments'));
    db.execute('PRAGMA foreign_keys = OFF;');
    db.execute(
      'INSERT INTO agent_installations (id, agent_kind, environment_id, '
      "executable_path, created_at) VALUES ('a1', 'x', 'e', 'p', 't');",
    );
    expect(
      db.query('SELECT leading_arguments FROM agent_installations;').first,
      {'leading_arguments': null},
    );
  });

  test('v66 run twice leaves one column', () {
    final raw = sqlite3.openInMemory();
    addTearDown(raw.close);
    for (var v = 1; v <= 66; v++) {
      schemaMigrations[v]!(raw);
    }
    expect(() => schemaMigrations[66]!(raw), returnsNormally);
    final columns = raw
        .select('PRAGMA table_info(agent_installations);')
        .map((r) => r['name'] as String);
    expect(columns.where((c) => c == 'leading_arguments'), hasLength(1));
  });

  test('v67 creates acp_agents with its defaults', () {
    expect(columnsOf('acp_agents'), [
      'id',
      'name',
      'command',
      'args',
      'env',
      'source',
      'registry_id',
      'created_at',
      // v68's column, after the ones v67 made.
      'icon_url',
      // v82's.
      'mode_rungs',
    ]);
    db.execute(
      'INSERT INTO acp_agents (id, name, command, source, created_at) '
      "VALUES ('r1', 'Mine', 'mine', 'custom', 't');",
    );
    expect(db.query('SELECT args, env, registry_id FROM acp_agents;').first, {
      'args': '[]',
      'env': '{}',
      'registry_id': null,
    });
    expect(
      () => db.execute(
        'INSERT INTO acp_agents (id, name, command, source, created_at) '
        "VALUES ('r1', 'Again', 'again', 'custom', 't');",
      ),
      throwsA(anything),
    );
  });

  test('v68 adds icon_url, null for every row written before', () {
    expect(columnsOf('acp_agents'), contains('icon_url'));
    db.execute(
      'INSERT INTO acp_agents (id, name, command, source, created_at) '
      "VALUES ('r1', 'Mine', 'mine', 'custom', 't');",
    );
    expect(db.query('SELECT icon_url FROM acp_agents;').first, {
      'icon_url': null,
    });
  });

  test('v68 run twice leaves one column', () {
    final raw = sqlite3.openInMemory();
    addTearDown(raw.close);
    for (var v = 1; v <= 68; v++) {
      schemaMigrations[v]!(raw);
    }
    expect(() => schemaMigrations[68]!(raw), returnsNormally);
    final columns = raw
        .select('PRAGMA table_info(acp_agents);')
        .map((r) => r['name'] as String);
    expect(columns.where((c) => c == 'icon_url'), hasLength(1));
  });

  test('v82 adds mode_rungs, an empty object for every row before, once', () {
    db.execute(
      'INSERT INTO acp_agents (id, name, command, source, created_at) '
      "VALUES ('r1', 'Mine', 'mine', 'custom', 't');",
    );
    expect(db.query('SELECT mode_rungs FROM acp_agents;').first, {
      'mode_rungs': '{}',
    });
    final raw = sqlite3.openInMemory();
    addTearDown(raw.close);
    for (var v = 1; v <= 82; v++) {
      schemaMigrations[v]!(raw);
    }
    expect(() => schemaMigrations[82]!(raw), returnsNormally);
  });
}
