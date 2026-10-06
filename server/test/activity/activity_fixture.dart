import 'package:karmashala_store/database.dart';

/// A store with one machine, two projects (`p1` Alpha, `p2` Beta) each with
/// one checkout (`r1`, `r2`), and one agent installation (`a1`).
AppDatabase activityStore() {
  final db = AppDatabase.memory();
  db.execute(
    'INSERT INTO execution_environments (id, kind, name, created_at) '
    "VALUES ('e1', 'windows', 'Desk', 't');",
  );
  for (final (p, r, name) in [('p1', 'r1', 'Alpha'), ('p2', 'r2', 'Beta')]) {
    db.execute(
      'INSERT INTO projects (id, name, root_environment_id, root_path, '
      "created_at) VALUES (?, ?, 'e1', ?, 't');",
      [p, name, '/$name'],
    );
    db.execute(
      'INSERT INTO repositories (id, project_id, name, environment_id, path, '
      "created_at) VALUES (?, ?, ?, 'e1', ?, 't');",
      [r, p, name, '/$name'],
    );
  }
  db.execute(
    'INSERT INTO agent_installations (id, agent_kind, environment_id, '
    "executable_path, created_at) VALUES ('a1', 'agentx', 'e1', '/x', 't');",
  );
  return db;
}

/// Inserts session [id] in checkout [repository], created at [at].
void insertSession(
  AppDatabase db,
  String id, {
  String repository = 'r1',
  required DateTime at,
  String status = 'running',
  String? parent,
  String? title,
  DateTime? archivedAt,
}) => db.execute(
  'INSERT INTO sessions (id, repository_id, agent_installation_id, title, '
  'use_worktree, status, created_at, parent_session_id, archived_at) '
  'VALUES (?, ?, ?, ?, 0, ?, ?, ?, ?);',
  [
    id,
    repository,
    'a1',
    title ?? 'Title $id',
    status,
    at.toUtc().toIso8601String(),
    parent,
    archivedAt?.toUtc().toIso8601String(),
  ],
);

/// Inserts imported session [id] in checkout [repository].
void insertImported(
  AppDatabase db,
  String id, {
  String repository = 'r1',
  required DateTime at,
  String filePath = '/store/x.jsonl',
}) => db.execute(
  'INSERT INTO imported_sessions (id, repository_id, source, external_id, '
  'environment_id, title, preview, file_path, store_home, is_subagent, '
  "created_at) VALUES (?, ?, 'agentx', ?, 'e1', ?, 'p', ?, '/store', 0, ?);",
  [id, repository, 'ext-$id', 'Imported $id', filePath, at.toIso8601String()],
);
