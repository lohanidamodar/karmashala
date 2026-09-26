import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala_core/util.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/data.dart';
import 'package:karmashala_host/src/sessions/session_sync_rows.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';

/// When every fixture row was launched.
final DateTime launchedAt = DateTime.utc(2026, 9, 1, 12);

/// The checkout every fixture reads: project `p1`, repository `r1`, on this
/// Windows machine.
const String repoPath = r'C:\src\demo\app';

/// The session sync's world, in a memory store the server's own data service
/// writes: one Windows environment and a WSL one, one checkout, an
/// installation per built-in agent (`a1` Claude Code, `a2` Codex, `a3`
/// Antigravity), and every change the other clients were told.
class SyncFixture {
  SyncFixture() : db = AppDatabase.memory() {
    data = DataService(db, clock: () => launchedAt);
    data
        .open((batch) => told.addAll(batch.changes))
        .handle(const DataSubscribe());
    const at = '2026-01-01T00:00:00.000Z';
    for (final (id, kind, name) in [
      ('windows', 'windowsNative', 'Windows'),
      ('wsl:Ubuntu', 'wsl', 'Ubuntu'),
    ]) {
      db.execute(
        'INSERT INTO execution_environments (id, kind, name, created_at) '
        'VALUES (?, ?, ?, ?);',
        [id, kind, name, at],
      );
    }
    db.execute(
      'INSERT INTO projects (id, name, root_environment_id, root_path, '
      "created_at) VALUES ('p1', 'Demo', 'windows', ?, ?);",
      [repoPath, at],
    );
    db.execute(
      'INSERT INTO repositories (id, project_id, name, environment_id, path, '
      "created_at) VALUES ('r1', 'p1', 'app', 'windows', ?, ?);",
      [repoPath, at],
    );
    for (final (id, agent, path) in [
      ('a1', AgentIds.claudeCode, 'claude'),
      ('a2', AgentIds.codex, 'codex'),
      ('a3', AgentIds.antigravity, 'agy'),
    ]) {
      db.execute(
        'INSERT INTO agent_installations '
        '(id, agent_kind, environment_id, executable_path, created_at) '
        "VALUES (?, ?, 'windows', ?, ?);",
        [id, agent, path, at],
      );
    }
    rows = SessionSyncRows(db, data, log: logs.add);
    sessions = SessionDao(db);
  }

  final AppDatabase db;
  late final DataService data;
  late final SessionSyncRows rows;
  late final SessionDao sessions;

  /// Every change another client was told, in order.
  final List<DataChange> told = [];
  final List<String> logs = [];

  /// The rows told changed, by id, in order.
  List<String> get toldRows => [
    for (final change in told)
      if (change is SessionRowChanged) change.session.id,
  ];

  /// Writes [session] as a client already had — straight into the store.
  void insert(Session session) => sessions.insert(session);

  Session? row(String id) => sessions.getById(id);

  void close() {
    rows.close();
    db.close();
  }
}

/// A session row as a launch writes it.
Session sessionRow({
  String id = 's1',
  String installation = 'a1',
  String title = 'New session',
  bool titleByUser = false,
  String? externalId,
  String? directory = repoPath,
  String? paneId,
  SessionStatus status = SessionStatus.running,
  Duration launchOffset = Duration.zero,
}) => Session(
  id: id,
  repositoryId: 'r1',
  agentInstallationId: installation,
  title: title,
  titleByUser: titleByUser,
  useWorktree: false,
  workingDirectory: directory == null
      ? null
      : EnvironmentPath(environmentId: 'windows', path: directory),
  status: status,
  createdAt: launchedAt.add(launchOffset),
  externalSessionId: externalId,
  paneId: paneId,
);

/// A conversation a store holds.
DetectedSession storeSession(
  String id, {
  String cli = AgentIds.claudeCode,
  String environmentId = 'windows',
  String cwd = repoPath,
  String? title,
  String preview = '',
  DateTime? startedAt,
  DateTime? modifiedAt,
}) => DetectedSession(
  cli: cli,
  sessionId: id,
  cwd: EnvironmentPath(environmentId: environmentId, path: cwd),
  filePath: 'C:\\store\\$id.jsonl',
  storeHome: r'C:\store',
  title: title,
  preview: preview,
  startedAt: startedAt,
  modifiedAt: modifiedAt,
);

/// A clock a test moves.
class MovableClock implements Clock {
  MovableClock(this.now);
  DateTime now;

  @override
  DateTime nowUtc() => now.toUtc();
}

/// Ids in order: `adopted-1`, `adopted-2`, …
String Function() sequentialIds([String prefix = 'adopted-']) {
  var next = 0;
  return () => '$prefix${++next}';
}
