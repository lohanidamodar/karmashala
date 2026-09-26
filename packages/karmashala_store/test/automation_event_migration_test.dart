import 'package:karmashala_store/database.dart';
import 'package:karmashala_store/migrations.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

/// Schema v57: automations that fire on an event, and the origin chain that
/// stops one answering its own action.
void main() {
  Set<String> columnsOf(Database db, String table) => {
    for (final row in db.select('PRAGMA table_info($table);'))
      row['name']! as String,
  };

  Database upTo(int version) {
    final raw = sqlite3.openInMemory();
    for (final step in schemaMigrations.keys.toList()..sort()) {
      if (step > version) break;
      schemaMigrations[step]!(raw);
    }
    return raw;
  }

  test('v57 adds the trigger, the run chain and the session origins', () {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    expect(db.schemaVersion, 59);
    final raw = upTo(57);
    addTearDown(raw.close);
    expect(
      columnsOf(raw, 'automations'),
      containsAll(['trigger_event', 'event_action']),
    );
    expect(
      columnsOf(raw, 'automation_runs'),
      containsAll(['origin', 'event_session_id']),
    );
    expect(columnsOf(raw, 'automation_session_origins'), {
      'session_id',
      'origin',
      'recorded_at',
    });
  });

  test('an automation armed before this is still time-based', () {
    final raw = upTo(56);
    addTearDown(raw.close);
    raw.execute(
      "INSERT INTO repositories (id, project_id, name, environment_id, path, "
      "created_at) VALUES ('r', 'p', 'app', 'windows', 'C:\\src', 't');",
    );
    raw.execute(
      "INSERT INTO automations (id, repository_id, name, cron, "
      "agent_installation_id, prompt, enabled, armed_at) "
      "VALUES ('a', 'r', 'Nightly', '0 3 * * *', 'i', 'go', 1, 't');",
    );
    raw.execute(
      "INSERT INTO automation_runs (id, automation_id, scheduled_for, "
      "fired_at, state) VALUES ('run', 'a', 't', 't', 'finished');",
    );
    schemaMigrations[57]!(raw);

    final automation = raw
        .select("SELECT * FROM automations WHERE id = 'a';")
        .single;
    expect(automation['cron'], '0 3 * * *');
    expect(automation['trigger_event'], isNull, reason: 'no event: a clock');
    expect(automation['event_action'], isNull);
    final run = raw.select("SELECT * FROM automation_runs WHERE id = 'run';");
    expect(run.single['origin'], isNull);
    expect(run.single['event_session_id'], isNull);
  });

  test('the step is idempotent', () {
    final raw = upTo(57);
    addTearDown(raw.close);
    schemaMigrations[57]!(raw);
    final added = raw
        .select('PRAGMA table_info(automations);')
        .where((row) => row['name'] == 'trigger_event');
    expect(added, hasLength(1));
  });
}
