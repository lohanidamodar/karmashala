import 'package:karmashala_store/database.dart';
import 'package:karmashala_store/migrations.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

/// Schema v93: an automation that runs a command, in a checkout or any
/// folder, and a run's exit code and output. The table is rebuilt, so the
/// rows that point at it must come through with it.
void main() {
  /// A database at v92 with an automation, its runs and its GitHub look,
  /// opened the way the server opens one: foreign keys on.
  AppDatabase atV92() {
    final raw = sqlite3.openInMemory();
    for (final step in schemaMigrations.keys.toList()..sort()) {
      if (step > 92) break;
      schemaMigrations[step]!(raw);
    }
    raw.execute('PRAGMA user_version = 92;');
    raw.execute(
      "INSERT INTO repositories (id, project_id, name, environment_id, path, "
      "created_at) VALUES ('r', 'p', 'app', 'windows', '/src', 't');",
    );
    raw.execute(
      "INSERT INTO automations (id, repository_id, name, cron, "
      "agent_installation_id, prompt, enabled, armed_at, steps) "
      "VALUES ('nightly', 'r', 'Nightly', '0 3 * * *', 'i', 'go', 1, 't', "
      "'[]');",
    );
    raw.execute(
      "INSERT INTO automation_runs (id, automation_id, scheduled_for, "
      "fired_at, state) VALUES ('run', 'nightly', 't', 't', 'finished');",
    );
    raw.execute(
      "INSERT INTO automation_github_state (automation_id, primed_at) "
      "VALUES ('nightly', 't');",
    );
    return AppDatabase(raw);
  }

  test('an existing automation, its runs and what points at it survive', () {
    final db = atV92();
    addTearDown(db.close);
    expect(db.schemaVersion, 94);
    final nightly = db
        .query("SELECT * FROM automations WHERE id = 'nightly';")
        .single;
    expect(nightly['repository_id'], 'r');
    expect(nightly['cron'], '0 3 * * *');
    expect(nightly['steps'], '[]');
    expect(nightly['command'], isNull);
    expect(nightly['folder_path'], isNull);
    expect(db.query('SELECT * FROM automation_runs;'), hasLength(1));
    expect(db.query('SELECT * FROM automation_github_state;'), hasLength(1));
    final run = db.query('SELECT * FROM automation_runs;').single;
    expect(run['exit_code'], isNull);
    expect(run['output'], isNull);
  });

  test('a folder automation names no checkout', () {
    final db = atV92();
    addTearDown(db.close);
    db.execute(
      "INSERT INTO automations (id, repository_id, name, cron, "
      "agent_installation_id, prompt, enabled, armed_at, command, "
      "folder_environment, folder_path) VALUES ('sync', NULL, 'Sync', "
      "'0 9 * * *', '', '', 1, 't', '{\"text\":\"date\"}', 'wsl', '~');",
    );
    expect(db.query("SELECT folder_path FROM automations WHERE id = 'sync';"), [
      {'folder_path': '~'},
    ]);
  });

  test('the checkout is still a foreign key, and still cascades', () {
    final db = atV92();
    addTearDown(db.close);
    expect(
      () => db.execute(
        "INSERT INTO automations (id, repository_id, name, "
        "agent_installation_id, prompt, enabled, armed_at) VALUES ('x', "
        "'gone', 'X', 'i', 'go', 1, 't');",
      ),
      throwsA(isA<SqliteException>()),
    );
    db.execute("DELETE FROM repositories WHERE id = 'r';");
    expect(db.query('SELECT * FROM automations;'), isEmpty);
    expect(db.query('SELECT * FROM automation_runs;'), isEmpty);
  });

  test('a fresh database has the same shape', () {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final info = db.query('PRAGMA table_info(automations);');
    final key = info.singleWhere((c) => c['name'] == 'repository_id');
    expect(key['notnull'], 0);
    expect(
      info.map((c) => c['name']),
      containsAll(['command', 'folder_environment', 'folder_path']),
    );
  });
}
