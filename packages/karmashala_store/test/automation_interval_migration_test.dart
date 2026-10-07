import 'package:karmashala_store/database.dart';
import 'package:karmashala_store/migrations.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

/// Schema v55: what a recurring automation needs to be left alone — a gap
/// measured from the last finish, a late policy, a failure budget and a
/// runtime ceiling.
///
/// Every column defaults to the behaviour automations already had, so an
/// upgrade cannot change what an armed one does.
void main() {
  test('v55 adds the columns, all of them optional', () {
    final db = AppDatabase.memory();
    addTearDown(db.close);

    final columns = {
      for (final row in db.query('PRAGMA table_info(automations);'))
        row['name']! as String: (
          notNull: row['notnull']! as int,
          fallback: row['dflt_value'],
        ),
    };
    expect(db.schemaVersion, 85);
    expect(columns['every_seconds']?.notNull, 0);
    expect(columns['max_runtime_seconds']?.notNull, 0);
    expect(columns['disabled_reason']?.notNull, 0);
    // The three that are not null carry the old behaviour as their default.
    expect(columns['late_policy']?.fallback, "'ask'");
    expect(columns['stop_after_failures']?.fallback, '3');
    expect(columns['consecutive_failures']?.fallback, '0');
  });

  test('an automation armed before this keeps firing exactly as it did', () {
    // The upgrade path that matters: a row written by the old schema must
    // read back as a cron automation with the old late behaviour.
    final raw = sqlite3.openInMemory();
    addTearDown(raw.close);
    for (final version in schemaMigrations.keys.toList()..sort()) {
      if (version >= 55) break;
      schemaMigrations[version]!(raw);
    }
    raw.execute(
      "INSERT INTO repositories (id, project_id, name, environment_id, path, "
      "created_at) VALUES ('r', 'p', 'app', 'windows', 'C:\\src', 't');",
    );
    raw.execute(
      "INSERT INTO automations (id, repository_id, name, cron, "
      "agent_installation_id, prompt, enabled, armed_at) "
      "VALUES ('a', 'r', 'Nightly', '0 3 * * *', 'i', 'go', 1, 't');",
    );
    schemaMigrations[55]!(raw);

    final row = raw.select("SELECT * FROM automations WHERE id = 'a';").single;
    expect(row['cron'], '0 3 * * *');
    expect(row['every_seconds'], isNull, reason: 'it is still a cron');
    expect(row['late_policy'], 'ask');
    expect(row['stop_after_failures'], 3);
    expect(row['consecutive_failures'], 0);
    expect(row['disabled_reason'], isNull);
    expect(row['max_runtime_seconds'], isNull, reason: 'no ceiling before');
  });

  test('the step is idempotent, as a re-numbered merge needs it to be', () {
    final raw = sqlite3.openInMemory();
    addTearDown(raw.close);
    for (final version in schemaMigrations.keys.toList()..sort()) {
      schemaMigrations[version]!(raw);
    }
    schemaMigrations[55]!(raw);
    final added = raw
        .select('PRAGMA table_info(automations);')
        .where((row) => row['name'] == 'every_seconds');
    expect(added, hasLength(1));
  });
}
