import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/database/migrations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

/// Applies every migration up to and including [upTo], the way `AppDatabase`
/// does, so a *pre-v23* database can be populated and then migrated.
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
  test('the head is v24 and the keys stay contiguous', () {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    expect(schemaMigrations.keys.toList()..sort(), [
      for (var v = 1; v <= schemaMigrations.length; v++) v,
    ]);
    expect(db.schemaVersion, schemaMigrations.length);
    expect(db.schemaVersion, 24);
  });

  test('v23 gives a session an append-only decision record', () {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final columns = {
      for (final row in db.query('PRAGMA table_info(session_decisions);'))
        row['name']! as String: row,
    };

    expect(columns.keys, {
      'id',
      'session_id',
      'sequence',
      'kind',
      'summary',
      'detail',
      'decided_by',
      'recorded_by_session_id',
      'origin_kind',
      'origin_id',
      'recorded_at',
    });

    // What a row cannot be without: whose record it is, where it sits in the
    // chain, what kind of decision it was, what was decided, which act
    // produced it, and when. Everything else is nullable because it is
    // genuinely sometimes unknown, and the packet renders that as
    // "not recorded".
    for (final required in const [
      'session_id',
      'sequence',
      'kind',
      'summary',
      'origin_kind',
      'recorded_at',
    ]) {
      expect(columns[required]!['notnull'], 1, reason: required);
    }
    for (final nullable in const [
      'detail',
      'decided_by',
      'recorded_by_session_id',
      'origin_id',
    ]) {
      expect(columns[nullable]!['notnull'], 0, reason: nullable);
      expect(columns[nullable]!['dflt_value'], isNull, reason: nullable);
    }
  });

  test('a sequence cannot be claimed twice in one session', () {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    void insert(String sessionId, int sequence) => db.execute(
      'INSERT INTO session_decisions '
      '(session_id, sequence, kind, summary, origin_kind, recorded_at) '
      'VALUES (?, ?, ?, ?, ?, ?);',
      [sessionId, sequence, 'constraintAccepted', 'x', 'decisionTool', 't'],
    );

    insert('s-1', 1);
    // The same position in another session's chain is a different fact.
    insert('s-2', 1);
    expect(() => insert('s-1', 1), throwsA(isA<SqliteException>()));
  });

  test('v23 invents no decisions for the sessions already there', () {
    final db = _migratedTo(22);
    addTearDown(db.close);
    db.execute('PRAGMA foreign_keys = OFF;');
    db.execute(
      'INSERT INTO sessions (id, repository_id, agent_installation_id, title, '
      'use_worktree, status, created_at, external_session_id, permission_mode) '
      "VALUES ('s-1', 'r-1', 'i-1', 'A long session', 0, 'running', "
      "'2026-08-01T00:00:00.000Z', 'ext-1', 'ask');",
    );
    db.execute(
      'INSERT INTO sessions (id, repository_id, agent_installation_id, title, '
      'use_worktree, status, created_at) '
      "VALUES ('s-2', 'r-1', 'i-1', 'Another', 0, 'idle', "
      "'2026-08-02T00:00:00.000Z');",
    );
    // The two records that *look* like decisions and are not: a checkpoint
    // says a turn happened, and a verification run says a check was made.
    db.execute(
      'INSERT INTO session_checkpoints (id, session_id, environment_id, '
      'repository_path, sequence, tree_sha, commit_sha, reason, created_at) '
      "VALUES ('c-1', 's-1', 'windows', 'C:/src', 1, 'tree', 'commit', "
      "'turn', '2026-08-01T01:00:00.000Z');",
    );
    db.execute(
      'INSERT INTO verification_runs (id, title, target_kind, target_url, '
      'started_at, artifact_directory, session_id, verdict) '
      "VALUES ('v-1', 'Login works', 'browser', 'http://x', "
      "'2026-08-01T02:00:00.000Z', 'C:/art', 's-1', 'pass');",
    );

    schemaMigrations[23]!(db);

    // Nothing that was there moved.
    final sessions = db.select('SELECT * FROM sessions ORDER BY id;');
    expect(sessions.length, 2);
    expect(sessions[0]['title'], 'A long session');
    expect(sessions[0]['external_session_id'], 'ext-1');
    expect(sessions[0]['permission_mode'], 'ask');
    expect(sessions[1]['title'], 'Another');
    expect(db.select('SELECT * FROM session_checkpoints;').single['id'], 'c-1');
    expect(db.select('SELECT * FROM verification_runs;').single['id'], 'v-1');

    // And no decision was manufactured from any of it. A checkpoint is not a
    // decision and a run this session may well have graded itself is not one
    // either; back-filling either would put words in the user's mouth for
    // every session that already exists.
    expect(db.select('SELECT * FROM session_decisions;'), isEmpty);
  });
}
