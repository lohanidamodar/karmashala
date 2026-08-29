import 'package:chitragupta/src/features/agents/domain/agent_installation.dart';
import 'package:chitragupta/src/features/agents/domain/agent_ids.dart';
import 'package:chitragupta/src/features/environments/domain/environment_kind.dart';
import 'package:chitragupta/src/features/environments/domain/environment_path.dart';
import 'package:chitragupta/src/features/environments/domain/execution_environment.dart';
import 'package:chitragupta/src/features/projects/domain/project.dart';
import 'package:chitragupta/src/features/repositories/domain/repository.dart';
import 'package:chitragupta/src/features/sessions/domain/session.dart';
import 'package:chitragupta/src/features/sessions/domain/session_event.dart';
import 'package:chitragupta/src/features/sessions/domain/session_status.dart';

/// Fixed timestamp used across tests for determinism.
final testTime = DateTime.utc(2026, 1, 2, 3, 4, 5);

ExecutionEnvironment windowsEnv({String id = 'windows'}) =>
    ExecutionEnvironment(
      id: id,
      kind: EnvironmentKind.windowsNative,
      name: 'Windows',
      createdAt: testTime,
    );

ExecutionEnvironment wslEnv({
  String id = 'wsl:Ubuntu',
  String distro = 'Ubuntu',
}) => ExecutionEnvironment(
  id: id,
  kind: EnvironmentKind.wsl,
  name: distro,
  wslDistribution: distro,
  createdAt: testTime,
);

Project project({
  String id = 'p1',
  String name = 'Demo',
  String environmentId = 'windows',
  String path = r'C:\src\demo',
}) => Project(
  id: id,
  name: name,
  root: EnvironmentPath(environmentId: environmentId, path: path),
  createdAt: testTime,
);

Repository repository({
  String id = 'r1',
  String projectId = 'p1',
  String name = 'app',
  String environmentId = 'windows',
  String path = r'C:\src\demo\app',
}) => Repository(
  id: id,
  projectId: projectId,
  name: name,
  path: EnvironmentPath(environmentId: environmentId, path: path),
  createdAt: testTime,
);

AgentInstallation agentInstallation({
  String id = 'a1',
  String agentId = AgentIds.claudeCode,
  String environmentId = 'windows',
  String path = r'C:\Users\me\.bin\claude.exe',
  String? version = '1.0.0',
}) => AgentInstallation(
  id: id,
  agentId: agentId,
  executable: EnvironmentPath(environmentId: environmentId, path: path),
  version: version,
  createdAt: testTime,
);

Session session({
  String id = 's1',
  String repositoryId = 'r1',
  String agentInstallationId = 'a1',
  String title = 'Work',
  bool useWorktree = false,
  EnvironmentPath? worktree,
  SessionStatus status = SessionStatus.created,
}) => Session(
  id: id,
  repositoryId: repositoryId,
  agentInstallationId: agentInstallationId,
  title: title,
  useWorktree: useWorktree,
  worktree: worktree,
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
