import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/database/migrations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

/// Applies every migration up to and including [upTo], the way `AppDatabase`
/// does, so a pre-v30 database can be populated and then migrated.
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
  test('v30 anchors a review thread to a file, a hash and a range', () {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final columns = {
      for (final row in db.query('PRAGMA table_info(review_threads);'))
        row['name']! as String: row,
    };

    expect(columns.keys, {
      'id',
      'repository_id',
      'file_path',
      'blob_sha',
      'start_line',
      'end_line',
      'anchor_excerpt',
      'status',
      'session_id',
      'created_at',
      'updated_at',
    });

    // What an anchor cannot be without. `blob_sha` is required because it is
    // the anchor's truth condition: a thread with no hash could never be told
    // apart from one whose file has moved on, which is the whole failure the
    // old `diffIndex` key had.
    for (final required in const [
      'repository_id',
      'file_path',
      'blob_sha',
      'status',
      'created_at',
      'updated_at',
    ]) {
      expect(columns[required]!['notnull'], 1, reason: required);
    }
    // A file-level comment is a real comment, so a range is genuinely optional
    // — and undefaulted, because a default of 0 or 1 would turn "about the
    // file" into a claim about a line nobody wrote about.
    for (final nullable in const [
      'start_line',
      'end_line',
      'anchor_excerpt',
      'session_id',
    ]) {
      expect(columns[nullable]!['notnull'], 0, reason: nullable);
      expect(columns[nullable]!['dflt_value'], isNull, reason: nullable);
    }
  });

  test('a comment always belongs to a thread, and holds its position', () {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final columns = {
      for (final row in db.query('PRAGMA table_info(review_thread_comments);'))
        row['name']! as String: row,
    };
    expect(columns.keys, {
      'id',
      'thread_id',
      'sequence',
      'author',
      'author_kind',
      'body',
      'created_at',
    });
    for (final required in columns.keys.where((name) => name != 'id')) {
      expect(columns[required]!['notnull'], 1, reason: required);
    }
  });

  test('two writers cannot claim the same position in one thread', () {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    db.execute('PRAGMA foreign_keys = OFF;');
    void insert(String threadId, int sequence) => db.execute(
      'INSERT INTO review_thread_comments (thread_id, sequence, author, '
      'author_kind, body, created_at) VALUES (?, ?, ?, ?, ?, ?);',
      [threadId, sequence, 'the user', 'user', 'x', 't'],
    );
    insert('t-1', 1);
    // The same position in another thread is a different fact.
    insert('t-2', 1);
    expect(() => insert('t-1', 1), throwsA(isA<SqliteException>()));
  });

  test('the index the panel reads by is the pair it queries on', () {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final indexes = db.query('PRAGMA index_list(review_threads);');
    expect(
      indexes.map((row) => row['name']),
      contains('idx_review_threads_repo_path'),
    );
    final columns = db.query(
      'PRAGMA index_info(idx_review_threads_repo_path);',
    );
    expect(columns.map((row) => row['name']), ['repository_id', 'file_path']);
  });

  test('v30 invents no review comments for the checkouts already there', () {
    final db = _migratedTo(29);
    addTearDown(db.close);
    db.execute('PRAGMA foreign_keys = OFF;');
    db.execute(
      'INSERT INTO projects (id, name, root_environment_id, root_path, '
      "created_at) VALUES ('p-1', 'Demo', 'windows', 'C:/src', "
      "'2026-08-01T00:00:00.000Z');",
    );
    db.execute(
      'INSERT INTO repositories (id, project_id, name, environment_id, path, '
      "created_at) VALUES ('r-1', 'p-1', 'app', 'windows', 'C:/src/app', "
      "'2026-08-01T00:00:00.000Z');",
    );

    schemaMigrations[30]!(db);

    expect(db.select('SELECT * FROM repositories;').single['id'], 'r-1');
    // Nothing to back-fill and nothing invented: the annotations this replaces
    // were never written to disk in any version of the schema, so an empty
    // table is the honest state rather than a loss.
    expect(db.select('SELECT * FROM review_threads;'), isEmpty);
    expect(db.select('SELECT * FROM review_thread_comments;'), isEmpty);
  });
}
