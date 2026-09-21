import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_store/migrations.dart';
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

  test('a conversation with no watermark is a real state, not a gap', () {
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

  group('v56', () {
    Database withV55Rows() {
      final db = _migratedTo(55);
      db.execute(
        'INSERT INTO conversation_turns (session_id, cli, ordinal, role, text) '
        "VALUES ('c1', 'claudeCode', 3, 'user', 'the stripe webhook secret');",
      );
      db.execute(
        'INSERT INTO conversation_index_state '
        '(session_id, cli, file_path, modified_at, size, turns, indexed_at) '
        "VALUES ('c1', 'claudeCode', 'C:/s/c1.jsonl', "
        "'2026-09-20T00:00:00.000Z', 900, 1, '2026-09-20T00:00:00.000Z');",
      );
      return db;
    }

    Set<String> columns(Database db, String table) => db
        .select('PRAGMA table_info($table);')
        .map((row) => row['name'] as String)
        .toSet();

    test('adds the resume point and the turn time, keeping every row', () {
      final db = withV55Rows();
      addTearDown(db.close);

      schemaMigrations[56]!(db);

      expect(
        columns(db, 'conversation_index_state'),
        containsAll(['read_offset', 'read_rows', 'read_anchor', 'read_head']),
      );
      expect(columns(db, 'conversation_turns'), contains('at'));
      final state = db.select('SELECT * FROM conversation_index_state;').single;
      // An old row has no resume point: its next change is read whole once,
      // which is what fills one in. Never a guessed offset.
      expect(state['read_offset'], isNull);
      expect(state['size'], 900);
      final hits = db.select(
        "SELECT rowid FROM conversation_turns_fts WHERE conversation_turns_fts "
        "MATCH 'webhook';",
      );
      expect(hits, hasLength(1), reason: 'the index still answers');
    });

    test('the vocabulary lists what the index already held', () {
      final db = withV55Rows();
      addTearDown(db.close);

      schemaMigrations[56]!(db);

      final terms = db
          .select('SELECT term FROM conversation_turns_vocab;')
          .map((row) => row['term'] as String);
      expect(terms, containsAll(['stripe', 'webhook', 'secret']));
    });

    test('is idempotent', () {
      final db = withV55Rows();
      addTearDown(db.close);

      schemaMigrations[56]!(db);
      final built = db.select('PRAGMA page_count;').first.values.first;
      schemaMigrations[56]!(db);

      expect(db.select('SELECT * FROM conversation_turns;'), hasLength(1));
      // The second run found the prefix option and rebuilt nothing.
      expect(db.select('PRAGMA page_count;').first.values.first, built);
      final vocab = db.select(
        "SELECT name FROM sqlite_master WHERE name = 'conversation_turns_vocab';",
      );
      expect(vocab, hasLength(1));
    });

    test('rebuilds the index with prefixes, and every row still answers', () {
      final db = _migratedTo(55);
      addTearDown(db.close);
      db.execute('BEGIN;');
      final insert = db.prepare(
        'INSERT INTO conversation_turns (session_id, cli, ordinal, role, text) '
        'VALUES (?, ?, ?, ?, ?);',
      );
      for (var i = 0; i < 20000; i++) {
        insert.execute(['c${i % 100}', 'claudeCode', i, 'user', 'turn $i']);
      }
      insert.close();
      db.execute('COMMIT;');
      schemaMigrations[56]!(db);

      final sql =
          db
                  .select(
                    'SELECT sql FROM sqlite_master '
                    "WHERE name = 'conversation_turns_fts';",
                  )
                  .single['sql']
              as String;
      expect(sql, contains("prefix = '2 3'"));
      expect(
        db.select('SELECT COUNT(*) AS n FROM conversation_turns;').single['n'],
        20000,
      );
      // Rebuilt from the table, not emptied: every turn is found again, by a
      // whole word and by the two-letter prefix the new index serves.
      expect(
        db
            .select(
              "SELECT COUNT(*) AS n FROM conversation_turns_fts "
              "WHERE conversation_turns_fts MATCH 'turn';",
            )
            .single['n'],
        20000,
      );
      expect(
        db
            .select(
              "SELECT COUNT(*) AS n FROM conversation_turns_fts "
              "WHERE conversation_turns_fts MATCH 'tu*';",
            )
            .single['n'],
        20000,
      );
      // And the triggers still feed it: a turn written after the swap is found.
      db.execute(
        'INSERT INTO conversation_turns (session_id, cli, ordinal, role, text) '
        "VALUES ('c1', 'claudeCode', 99999, 'user', 'afterwards');",
      );
      expect(
        db.select(
          "SELECT rowid FROM conversation_turns_fts "
          "WHERE conversation_turns_fts MATCH 'afterwards';",
        ),
        hasLength(1),
      );
    });
  });
}
