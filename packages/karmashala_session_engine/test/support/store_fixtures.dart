import 'package:agent_cli/process.dart';
import 'package:karmashala_session/events.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_store/database.dart';

/// Fixed timestamp used across these tests for determinism.
final testTime = DateTime.utc(2026, 1, 2, 3, 4, 5);

/// What a session row points at, written as the server's store holds it: the
/// environment `windows`, project `p1`, its checkout `r1` and installation
/// `a1`.
void seedWorkspace(AppDatabase db) {
  final at = testTime.toIso8601String();
  db.execute(
    'INSERT INTO execution_environments (id, kind, name, created_at) '
    "VALUES ('windows', 'windowsNative', 'Windows', ?);",
    [at],
  );
  db.execute(
    'INSERT INTO projects (id, name, root_environment_id, root_path, '
    "created_at) VALUES ('p1', 'Demo', 'windows', 'C:\\src\\demo', ?);",
    [at],
  );
  db.execute(
    'INSERT INTO repositories '
    '(id, project_id, name, environment_id, path, created_at) '
    "VALUES ('r1', 'p1', 'app', 'windows', 'C:\\src\\demo\\app', ?);",
    [at],
  );
  db.execute(
    'INSERT INTO agent_installations '
    '(id, agent_kind, environment_id, executable_path, created_at) '
    "VALUES ('a1', 'claude-code', 'windows', 'claude.exe', ?);",
    [at],
  );
}

/// Deletes checkout [id] — the cascade a project delete runs.
void deleteRepository(AppDatabase db, String id) =>
    db.execute('DELETE FROM repositories WHERE id = ?;', [id]);

Session session({
  String id = 's1',
  String repositoryId = 'r1',
  String agentInstallationId = 'a1',
  String title = 'Work',
  bool useWorktree = false,
  EnvironmentPath? worktree,
  EnvironmentPath? workingDirectory,
  SessionStatus status = SessionStatus.created,
}) => Session(
  id: id,
  repositoryId: repositoryId,
  agentInstallationId: agentInstallationId,
  title: title,
  useWorktree: useWorktree,
  worktree: worktree,
  workingDirectory: workingDirectory,
  status: status,
  createdAt: testTime,
);

SessionEvent event({
  String sessionId = 's1',
  String type = 'message.agent',
  String payload = '{"text":"hi"}',
}) => SessionEvent(
  sessionId: sessionId,
  seq: 0,
  type: type,
  payload: payload,
  createdAt: testTime,
);
