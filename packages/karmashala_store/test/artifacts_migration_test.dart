import 'package:karmashala_store/migrations.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

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

/// v79: a session's artifacts and the snapshot of each revision.
void main() {
  test('v79 adds the artifact and revision tables', () {
    final db = _migratedTo(78);
    addTearDown(db.close);

    schemaMigrations[79]!(db);

    List<String> columns(String table) => [
      for (final row in db.select('PRAGMA table_info($table);'))
        row['name'] as String,
    ];
    expect(
      columns('session_artifacts'),
      containsAll([
        'id',
        'session_id',
        'title',
        'kind',
        'mode',
        'origin',
        'source_environment_id',
        'source_path',
        'file_name',
        'revision',
        'network_allowed',
        'source_state',
        'source_problem',
        'created_at',
        'updated_at',
      ]),
    );
    expect(
      columns('session_artifact_revisions'),
      containsAll(['artifact_id', 'revision', 'size', 'digest', 'path']),
    );
  });

  test('a revision goes with its artifact', () {
    final db = _migratedTo(79);
    addTearDown(db.close);
    db.execute('PRAGMA foreign_keys = ON;');
    db.execute(
      "INSERT INTO session_artifacts (id, session_id, title, kind, mode, "
      "origin, file_name, revision, size, mime_type, created_at, updated_at) "
      "VALUES ('a1', 's1', 'T', 'html', 'inline', 'tool', 'x.html', 1, 3, "
      "'text/html', '2026-10-06T00:00:00.000Z', '2026-10-06T00:00:00.000Z');",
    );
    db.execute(
      "INSERT INTO session_artifact_revisions (artifact_id, revision, size, "
      "digest, path, captured_at) VALUES ('a1', 1, 3, 'd', '/p', "
      "'2026-10-06T00:00:00.000Z');",
    );
    db.execute("DELETE FROM session_artifacts WHERE id = 'a1';");
    expect(db.select('SELECT * FROM session_artifact_revisions;'), isEmpty);
  });
}
