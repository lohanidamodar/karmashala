import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart' hide Clock;
import 'package:agent_cli/process.dart';
import 'package:agent_cli/read.dart' show ImportedSession;
import 'package:karmashala_core/util.dart';
import 'package:karmashala_environments/store.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_projects/karmashala_projects.dart';
import 'package:karmashala_projects/store.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';

/// Fixed timestamp used across these tests for determinism.
final testTime = DateTime.utc(2026, 1, 2, 3, 4, 5);

/// A clock a test moves by hand.
class MovableClock implements Clock {
  MovableClock(this.now);

  DateTime now;

  @override
  DateTime nowUtc() => now.toUtc();

  void advance(Duration by) => now = now.add(by);
}

/// The rows the index joins — sessions, imported history, checkouts and
/// installations — written straight into the server's store, as the server's
/// own DAOs write them.
class Seed {
  Seed(this.db);

  final AppDatabase db;

  late final environments = ExecutionEnvironmentDao(db);
  late final installations = AgentInstallationDao(db);
  late final projects = ProjectDao(db);
  late final repositories = RepositoryDao(db);
  late final sessions = SessionDao(db);
  late final imported = ImportedSessionDao(db);

  /// This machine, project `p1` with checkout `r1`, and Claude Code as `a1`.
  Seed workspace() {
    environments.upsert(windowsEnv());
    projects.insert(project());
    repositories.insert(repository());
    installations.insert(agentInstallation());
    return this;
  }

  void session(
    String id, {
    String? externalSessionId,
    String repositoryId = 'r1',
    String agentInstallationId = 'a1',
    String title = 'Work',
  }) => sessions.insert(
    Session(
      id: id,
      repositoryId: repositoryId,
      agentInstallationId: agentInstallationId,
      title: title,
      useWorktree: false,
      workingDirectory: const EnvironmentPath(
        environmentId: 'windows',
        path: r'C:\src\demo\app',
      ),
      status: SessionStatus.running,
      createdAt: testTime,
      externalSessionId: externalSessionId,
    ),
  );

  void importedSession(
    String externalId,
    String filePath, {
    String repositoryId = 'r1',
    String cli = AgentIds.claudeCode,
    String storeHome = '/store',
  }) => imported.insertIfAbsent(
    ImportedSession(
      id: 'i-$externalId',
      repositoryId: repositoryId,
      cli: cli,
      externalId: externalId,
      environmentId: 'windows',
      filePath: filePath,
      storeHome: storeHome,
      isSubagent: false,
      preview: 'preview',
      createdAt: testTime,
    ),
  );
}

ExecutionEnvironment windowsEnv({String id = 'windows'}) =>
    ExecutionEnvironment(
      id: id,
      kind: EnvironmentKind.windowsNative,
      name: 'Windows',
      createdAt: testTime,
    );

Project project({
  String id = 'p1',
  String name = 'Demo',
  String path = r'C:\src\demo',
}) => Project(
  id: id,
  name: name,
  root: EnvironmentPath(environmentId: 'windows', path: path),
  createdAt: testTime,
);

Repository repository({
  String id = 'r1',
  String projectId = 'p1',
  String path = r'C:\src\demo\app',
}) => Repository(
  id: id,
  projectId: projectId,
  name: 'app',
  path: EnvironmentPath(environmentId: 'windows', path: path),
  createdAt: testTime,
);

AgentInstallation agentInstallation({
  String id = 'a1',
  String agentId = AgentIds.claudeCode,
}) => AgentInstallation(
  id: id,
  agentId: agentId,
  executable: EnvironmentPath(
    environmentId: 'windows',
    path: r'C:\Users\me\.bin\claude.exe',
  ),
  version: '1.0.0',
  createdAt: testTime,
);
