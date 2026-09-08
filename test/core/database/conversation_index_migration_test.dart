import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/database/migrations.dart';
import 'package:sqlite3/sqlite3.dart';

/// Applies every migration up to and including [upTo].
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
  test('v41 indexes a turn and finds it back through MATCH', () {
    final db = _migratedTo(41);
    addTearDown(db.close);
    db.execute(
      'INSERT INTO conversation_turns (session_id, cli, ordinal, role, text) '
      "VALUES ('c1', 'claudeCode', 3, 'user', "
      "'we decided to keep the worktree copy');",
    );

    final hits = db.select(
      'SELECT t.session_id, t.ordinal, t.role FROM conversation_turns_fts f '
      'JOIN conversation_turns t ON t.id = f.rowid '
      "WHERE f.text MATCH 'worktree';",
    );
    expect(hits.single['session_id'], 'c1');
    expect(hits.single['ordinal'], 3);
    expect(hits.single['role'], 'user');
  });

  test('deleting a conversation takes its rows out of the index too', () {
    final db = _migratedTo(41);
    addTearDown(db.close);
    db.execute(
      'INSERT INTO conversation_turns (session_id, cli, ordinal, role, text) '
      "VALUES ('c1', 'claudeCode', 0, 'user', 'a note about caching');",
    );
    db.execute("DELETE FROM conversation_turns WHERE session_id = 'c1';");

    // The external-content delete trigger is what makes this true; without it
    // the FTS index keeps answering for text no table holds any more.
    final hits = db.select(
      "SELECT rowid FROM conversation_turns_fts WHERE conversation_turns_fts "
      "MATCH 'caching';",
    );
    expect(hits, isEmpty);
  });

  test('re-indexing one conversation leaves the others alone', () {
    final db = _migratedTo(41);
    addTearDown(db.close);
    db.execute(
      'INSERT INTO conversation_turns (session_id, cli, ordinal, role, text) '
      "VALUES ('c1', 'claudeCode', 0, 'user', 'caching in the first'), "
      "('c2', 'codex', 0, 'user', 'caching in the second');",
    );
    db.execute("DELETE FROM conversation_turns WHERE session_id = 'c1';");

    final hits = db.select(
      'SELECT t.session_id FROM conversation_turns_fts f '
      'JOIN conversation_turns t ON t.id = f.rowid '
      "WHERE f.text MATCH 'caching';",
    );
    expect(hits.map((row) => row['session_id']), ['c2']);
  });

  test('the delete is an index seek, not a walk over every turn', () {
    final db = _migratedTo(41);
    addTearDown(db.close);
    // The claim the whole table split exists for: one conversation's rows are
    // reachable without reading another conversation's.
    final plan = db
        .select(
          'EXPLAIN QUERY PLAN '
          'DELETE FROM conversation_turns WHERE session_id = ?;',
          ['c1'],
        )
        .map((row) => row['detail'] as String)
        .join(' ');
    expect(plan, contains('idx_conversation_turns_session'));
  });

  test('v41 is idempotent, the way every step here has to be', () {
    final db = _migratedTo(40);
    addTearDown(db.close);

    schemaMigrations[41]!(db);
    schemaMigrations[41]!(db);

    final tables = db
        .select("SELECT name FROM sqlite_master WHERE type = 'table';")
        .map((row) => row['name'] as String);
    expect(tables.where((t) => t == 'conversation_turns'), hasLength(1));
    expect(tables.where((t) => t == 'conversation_index_state'), hasLength(1));
  });

  test('a conversation with no watermark is a real state, not a missing one', () {
    final db = _migratedTo(41);
    addTearDown(db.close);
    // A transcript read from a path we could not stat is indexed all the same;
    // it simply has nothing to skip on next time. An unknown is not a zero.
    db.execute(
      'INSERT INTO conversation_index_state '
      '(session_id, cli, file_path, turns, indexed_at) '
      "VALUES ('c1', 'codex', '/tmp/x.jsonl', 4, '2026-09-08T00:00:00Z');",
    );
    final row = db.select('SELECT * FROM conversation_index_state;').single;
    expect(row['modified_at'], isNull);
    expect(row['size'], isNull);
    expect(row['turns'], 4);
  });
}
