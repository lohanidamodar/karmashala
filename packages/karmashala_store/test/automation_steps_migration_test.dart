import 'package:karmashala_store/migrations.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

/// Schema v84: every automation's model, worktree and steps; a run's cause and
/// what its steps did.
void main() {
  Database upTo(int version) {
    final raw = sqlite3.openInMemory();
    for (final step in schemaMigrations.keys.toList()..sort()) {
      if (step > version) break;
      schemaMigrations[step]!(raw);
    }
    return raw;
  }

  void seed(Database raw) {
    raw.execute(
      "INSERT INTO repositories (id, project_id, name, environment_id, path, "
      "created_at) VALUES ('r', 'p', 'app', 'windows', 'C:\\src', 't');",
    );
    raw.execute(
      "INSERT INTO automations (id, repository_id, name, cron, "
      "agent_installation_id, prompt, enabled, armed_at) "
      "VALUES ('nightly', 'r', 'Nightly', '0 3 * * *', 'i', 'go', 1, 't');",
    );
    raw.execute(
      "INSERT INTO automations (id, repository_id, name, "
      "agent_installation_id, prompt, enabled, armed_at, webhook_id, "
      "webhook_model, webhook_worktree) VALUES ('hook', 'r', 'Triage', 'i', "
      "'go', 1, 't', 'h1', 'opus', 1);",
    );
    raw.execute(
      "INSERT INTO automation_runs (id, automation_id, scheduled_for, "
      "fired_at, state) VALUES ('run', 'nightly', 't', 't', 'finished');",
    );
  }

  test('an existing automation keeps its behaviour', () {
    final raw = upTo(83);
    addTearDown(raw.close);
    seed(raw);
    schemaMigrations[84]!(raw);

    final nightly = raw
        .select("SELECT * FROM automations WHERE id = 'nightly';")
        .single;
    expect(nightly['cron'], '0 3 * * *');
    expect(nightly['steps'], isNull, reason: 'null reads as its checks');
    expect(nightly['model_id'], isNull);
    expect(nightly['run_in_worktree'], 0);
    final run = raw
        .select("SELECT * FROM automation_runs WHERE id = 'run';")
        .single;
    expect(run['started_by'], isNull);
    expect(run['step_results'], isNull);
  });

  test("a webhook's model and worktree become the automation's", () {
    final raw = upTo(83);
    addTearDown(raw.close);
    seed(raw);
    schemaMigrations[84]!(raw);
    final hook = raw.select("SELECT * FROM automations WHERE id = 'hook';");
    expect(hook.single['model_id'], 'opus');
    expect(hook.single['run_in_worktree'], 1);
  });

  test('v85 keeps the prompt a webhook run was given, on the run', () {
    final raw = upTo(85);
    addTearDown(raw.close);
    final columns = raw
        .select('PRAGMA table_info(automation_runs);')
        .map((row) => row['name']);
    expect(columns, contains('prompt'));
    final calls = raw
        .select('PRAGMA table_info(webhook_calls);')
        .map((row) => row['name']);
    expect(calls, isNot(contains('prompt')), reason: 'the call log keeps none');
    schemaMigrations[85]!(raw);
  });

  test('the step is idempotent', () {
    final raw = upTo(84);
    addTearDown(raw.close);
    schemaMigrations[84]!(raw);
    final added = raw
        .select('PRAGMA table_info(automations);')
        .where((row) => row['name'] == 'steps');
    expect(added, hasLength(1));
  });
}
