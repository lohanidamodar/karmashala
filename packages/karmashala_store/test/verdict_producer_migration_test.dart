import 'package:karmashala_store/migrations.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

/// Applies every migration up to and including [upTo], the way `AppDatabase`
/// does, so a *pre-v20* database can be populated and then migrated.
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
  test('v20 upgrades an existing database without losing a verdict', () {
    final db = _migratedTo(19);
    addTearDown(db.close);
    db.execute('PRAGMA foreign_keys = OFF;');
    db.execute(
      'INSERT INTO verification_runs '
      '(id, title, target_kind, target_url, session_id, started_at, '
      'finished_at, verdict, reason, artifact_directory) '
      "VALUES ('run-old', 'Old run', 'browser', 'https://example.com', "
      "'s-1', '2026-08-01T00:00:00.000Z', '2026-08-01T00:01:00.000Z', "
      "'pass', 'It worked', 'C:/old');",
    );

    schemaMigrations[20]!(db);

    final row = db.select('SELECT * FROM verification_runs WHERE id = ?;', [
      'run-old',
    ]).first;
    // Everything the row said before still says it.
    expect(row['verdict'], 'pass');
    expect(row['reason'], 'It worked');
    expect(row['session_id'], 's-1');
    // And the one new thing is honestly empty rather than invented.
    expect(row['produced_by_session_id'], isNull);
  });

  test('v20 does not backfill the producer from the subject', () {
    // The tempting backfill — "the session it belongs to must have graded it"
    // — would assert a fact nobody recorded, and would make every historical
    // verdict read as self-graded whether or not it was. v16's backfill was a
    // fact; this one would be a guess, so there isn't one.
    final db = _migratedTo(19);
    addTearDown(db.close);
    db.execute('PRAGMA foreign_keys = OFF;');
    db.execute(
      'INSERT INTO fanout_comparisons '
      '(id, repository_id, prompt, created_at, outcome) '
      "VALUES ('cmp-1', 'repo-1', 'do the thing', '2026-08-01', 'pending');",
    );
    db.execute(
      'INSERT INTO fanout_candidates '
      '(id, comparison_id, position, session_id, installation_id, agent_id, '
      'launch, verdict, verdict_label) '
      "VALUES ('cand-1', 'cmp-1', 0, 's-1', 'inst-1', 'agent-1', 'started', "
      "'passed', '8 tests');",
    );

    schemaMigrations[20]!(db);

    final row = db.select('SELECT * FROM fanout_candidates WHERE id = ?;', [
      'cand-1',
    ]).first;
    expect(row['verdict'], 'passed');
    expect(row['verdict_label'], '8 tests');
    expect(row['session_id'], 's-1');
    expect(row['verdict_producer_session_id'], isNull);
  });

  test('a database already at v20 has each column exactly once', () {
    // `ALTER TABLE ... ADD COLUMN` cannot be made idempotent and does not have
    // to be: `AppDatabase` runs each step once, guarded by `user_version`.
    final db = _migratedTo(20);
    addTearDown(db.close);
    List<Object?> columnsOf(String table) =>
        db.select('PRAGMA table_info($table);').map((r) => r['name']).toList();
    expect(
      columnsOf(
        'verification_runs',
      ).where((c) => c == 'produced_by_session_id'),
      hasLength(1),
    );
    expect(
      columnsOf(
        'fanout_candidates',
      ).where((c) => c == 'verdict_producer_session_id'),
      hasLength(1),
    );
  });
}
