import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/database/migrations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

/// Applies every migration up to and including [upTo], the way `AppDatabase`
/// does, so a *pre-v25* database can be populated and then migrated.
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
  test('the head is v33 and the keys stay contiguous', () {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    expect(schemaMigrations.keys.toList()..sort(), [
      for (var v = 1; v <= schemaMigrations.length; v++) v,
    ]);
    expect(db.schemaVersion, 34);
  });

  test('v25 gives a session somewhere to record what it left', () {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final columns = {
      for (final row in db.query('PRAGMA table_info(session_follow_ups);'))
        row['name']! as String: row,
    };

    expect(columns.keys, {
      'id',
      'session_id',
      'reason',
      'ending',
      'summary',
      'raised_at',
      'resolved_at',
      'resolution',
    });

    // What a follow-up cannot be without: whose it is, why it was raised, how
    // the session ended, and when we noticed. The rest is nullable because it
    // is genuinely sometimes unknown — a summary the source never gave, and a
    // resolution an *open* follow-up has not got yet.
    for (final required in const [
      'session_id',
      'reason',
      'ending',
      'raised_at',
    ]) {
      expect(columns[required]!['notnull'], 1, reason: required);
    }
    for (final nullable in const ['summary', 'resolved_at', 'resolution']) {
      expect(columns[nullable]!['notnull'], 0, reason: nullable);
    }
  });

  test('a session may have at most one open follow-up', () {
    // Enforced by the schema rather than by the caller, because the caller is
    // a poll: it re-notices the same ended session on every revision bump, and
    // without this the list would grow by one row a second.
    final db = AppDatabase.memory();
    addTearDown(db.close);
    void raise({String? resolvedAt}) => db.execute(
      'INSERT INTO session_follow_ups '
      '(session_id, reason, ending, raised_at, resolved_at) '
      'VALUES (?, ?, ?, ?, ?);',
      ['s1', 'endedInFailure', 'failed', '2026-09-01T10:00:00.000Z', resolvedAt],
    );

    raise();
    expect(raise, throwsA(isA<SqliteException>()));

    // Resolved ones are exempt: the same session ending twice over a week is
    // two things to come back to, and only the second is still open.
    db.execute(
      'UPDATE session_follow_ups SET resolved_at = ? WHERE session_id = ?;',
      ['2026-09-01T11:00:00.000Z', 's1'],
    );
    raise();
    raise(resolvedAt: '2026-09-01T12:00:00.000Z');
    expect(
      db
          .query('SELECT COUNT(*) AS n FROM session_follow_ups;')
          .first['n'],
      3,
    );
  });

  test('v24 databases gain the table and lose nothing', () {
    final db = _migratedTo(24);
    addTearDown(db.close);
    db.execute('PRAGMA foreign_keys = OFF;');
    db.execute(
      'INSERT INTO sessions (id, repository_id, agent_installation_id, title, '
      'use_worktree, status, created_at) '
      "VALUES ('s-1', 'r-1', 'i-1', 'A finished session', 0, 'failed', "
      "'2026-08-01T00:00:00.000Z');",
    );

    schemaMigrations[25]!(db);

    expect(db.select('SELECT * FROM sessions;').length, 1);
  });

  test('sessions that ended before the feature are marked, never raised', () {
    // The observer's durable signal is the session's own row, and a row that
    // says `failed` says it forever. Without this the first sweep after an
    // upgrade would present a workspace's whole history as things that just
    // happened.
    final db = _migratedTo(24);
    addTearDown(db.close);
    db.execute('PRAGMA foreign_keys = OFF;');
    void insert(String id, String status) => db.execute(
      'INSERT INTO sessions (id, repository_id, agent_installation_id, title, '
      'use_worktree, status, created_at) '
      "VALUES (?, 'r-1', 'i-1', ?, 0, ?, '2026-08-01T00:00:00.000Z');",
      [id, 'Session $id', status],
    );
    insert('s-failed', 'failed');
    insert('s-done', 'completed');
    insert('s-stopped', 'cancelled');
    insert('s-live', 'running');
    insert('s-idle', 'idle');

    schemaMigrations[25]!(db);

    // Nothing is open, so nothing is shown.
    expect(
      db
          .select(
            'SELECT COUNT(*) AS n FROM session_follow_ups '
            'WHERE resolved_at IS NULL;',
          )
          .first['n'],
      0,
    );
    // One closed mark per session that had already ended, and none for the two
    // still live — those have not ended yet, and when they do the app will
    // notice properly.
    final marks = db.select(
      'SELECT * FROM session_follow_ups '
      'ORDER BY session_id;',
    );
    expect(marks.map((row) => row['session_id']), [
      's-done',
      's-failed',
      's-stopped',
    ]);
    // The ending is the row's own status word, which is exactly what
    // `endingOfStatus` produces — so the mark matches what the service looks
    // for.
    expect(marks.map((row) => row['ending']), [
      'completed',
      'failed',
      'cancelled',
    ]);
    for (final row in marks) {
      expect(row['reason'], 'predatesTheFeature');
      // Closed, with no resolution recorded: nobody decided anything about
      // these, they simply predate the question.
      expect(row['resolved_at'], isNotNull);
      expect(row['resolution'], isNull);
    }
  });
}
