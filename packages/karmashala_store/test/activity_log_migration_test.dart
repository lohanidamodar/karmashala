import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

/// v80: `activity_log`, the timeline's own history. No foreign keys, and the
/// triggers on `sessions` append what happens to a row instead of joining it.
void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.memory();
    db.execute(
      'INSERT INTO execution_environments (id, kind, name, created_at) '
      "VALUES ('e1', 'windows', 'Desk', 't');",
    );
    db.execute(
      'INSERT INTO projects (id, name, root_environment_id, root_path, '
      "created_at) VALUES ('p1', 'Alpha', 'e1', '/alpha', 't');",
    );
    db.execute(
      'INSERT INTO repositories (id, project_id, name, environment_id, path, '
      "created_at) VALUES ('r1', 'p1', 'alpha', 'e1', '/alpha', 't');",
    );
    db.execute(
      'INSERT INTO agent_installations (id, agent_kind, environment_id, '
      "executable_path, created_at) VALUES ('a1', 'agentx', 'e1', '/x', 't');",
    );
  });
  tearDown(() => db.close());

  void insertSession(String id, {String? parent, String? worktree}) =>
      db.execute(
        'INSERT INTO sessions (id, repository_id, agent_installation_id, '
        'title, use_worktree, worktree_path, status, created_at, '
        'parent_session_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);',
        [
          id,
          'r1',
          'a1',
          'Title $id',
          worktree == null ? 0 : 1,
          worktree,
          'running',
          '2026-10-06T09:00:00.000Z',
          parent,
        ],
      );

  List<Map<String, Object?>> log([String? sessionId]) => db.query(
    'SELECT * FROM activity_log '
    '${sessionId == null ? '' : 'WHERE session_id = ?'} ORDER BY id;',
    [?sessionId],
  );

  test('the head is 90', () => expect(db.schemaVersion, 90));

  test('v80 creates activity_log with its indexes and no foreign keys', () {
    final columns = db
        .query('PRAGMA table_info(activity_log);')
        .map((r) => r['name']! as String)
        .toList();
    expect(columns, [
      'id',
      'at',
      'kind',
      'session_id',
      'title',
      'project_id',
      'project_name',
      'checkout_path',
      'agent',
      'machine',
      'parent_session_id',
      'detail',
      'source',
      'source_id',
      'backfilled',
      'approximate',
      'recorded_at',
    ]);
    expect(db.query('PRAGMA foreign_key_list(activity_log);'), isEmpty);
    final indexes = db
        .query('PRAGMA index_list(activity_log);')
        .map((r) => r['name'])
        .toSet();
    expect(
      indexes,
      containsAll([
        'idx_activity_log_at',
        'idx_activity_log_project_at',
        'idx_activity_log_session_at',
      ]),
    );
  });

  test('a new session appends its start with its own copy of the row', () {
    insertSession('s1', worktree: '/alpha-wt');
    final rows = log('s1');
    expect(rows, hasLength(1));
    expect(rows.single, containsPair('kind', 'sessionStarted'));
    expect(rows.single, containsPair('at', '2026-10-06T09:00:00.000Z'));
    expect(rows.single, containsPair('title', 'Title s1'));
    expect(rows.single, containsPair('project_id', 'p1'));
    expect(rows.single, containsPair('project_name', 'Alpha'));
    expect(rows.single, containsPair('checkout_path', '/alpha-wt'));
    expect(rows.single, containsPair('agent', 'agentx'));
    expect(rows.single, containsPair('machine', 'Desk'));
    expect(rows.single, containsPair('backfilled', 0));
    expect(rows.single, containsPair('source', 'session'));
    expect(rows.single, containsPair('source_id', 's1:started'));
  });

  test('a child session also appends the link from its parent', () {
    insertSession('p');
    insertSession('c', parent: 'p');
    final linked = log('c').where((r) => r['kind'] == 'linked').single;
    expect(linked['parent_session_id'], 'p');
    expect(linked['source'], 'lineage');
    expect(linked['source_id'], 'c');
  });

  test('a rename appends and keeps the old title on the earlier entry', () {
    insertSession('s1');
    db.execute("UPDATE sessions SET title = 'New' WHERE id = 's1';");
    db.execute("UPDATE sessions SET status = 'idle' WHERE id = 's1';");
    final rows = log('s1');
    expect(rows.map((r) => r['kind']), ['sessionStarted', 'renamed']);
    expect(rows.first['title'], 'Title s1');
    expect(rows.last['title'], 'New');
    expect(rows.last['detail'], 'New');
  });

  test('archiving and unarchiving each append', () {
    insertSession('s1');
    db.execute(
      "UPDATE sessions SET archived_at = '2026-10-06T10:00:00.000Z' "
      "WHERE id = 's1';",
    );
    db.execute("UPDATE sessions SET archived_at = NULL WHERE id = 's1';");
    expect(log('s1').map((r) => r['kind']), [
      'sessionStarted',
      'archived',
      'unarchived',
    ]);
    expect(log('s1')[1]['at'], '2026-10-06T10:00:00.000Z');
  });

  test('an entry survives deleting its session, checkout and project', () {
    insertSession('s1', worktree: '/alpha-wt');
    db.execute("DELETE FROM sessions WHERE id = 's1';");
    db.execute("DELETE FROM repositories WHERE id = 'r1';");
    db.execute("DELETE FROM projects WHERE id = 'p1';");
    final rows = log('s1');
    expect(rows.map((r) => r['kind']), ['sessionStarted', 'deleted']);
    for (final row in rows) {
      expect(row['title'], 'Title s1');
      expect(row['project_name'], 'Alpha');
      expect(row['checkout_path'], '/alpha-wt');
    }
  });

  test('a session cascaded away with its project appends its delete, '
      'carrying the copy it was logged with', () {
    insertSession('s1');
    db.execute("DELETE FROM projects WHERE id = 'p1';");
    final deleted = log('s1').singleWhere((r) => r['kind'] == 'deleted');
    expect(deleted['project_id'], 'p1');
    expect(deleted['project_name'], 'Alpha');
    expect(deleted['title'], 'Title s1');
  });

  test('a duplicate key is ignored, never an error for the write it rides '
      'on', () {
    db.execute(
      'INSERT INTO activity_log (at, kind, session_id, source, source_id, '
      "backfilled, approximate, recorded_at) VALUES ('t', 'sessionStarted', "
      "'s1', 'session', 's1:started', 1, 0, 't');",
    );
    insertSession('s1');
    final rows = log('s1');
    expect(rows, hasLength(1));
    expect(rows.single['backfilled'], 1);
  });
}
