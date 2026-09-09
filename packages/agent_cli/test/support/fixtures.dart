import 'package:agent_cli/src/agents/domain/agent_ids.dart';
import 'package:agent_cli/src/agents/domain/agent_installation.dart';
import 'package:agent_cli/src/environments/environment_kind.dart';
import 'package:agent_cli/src/environments/environment_path.dart';
import 'package:agent_cli/src/environments/execution_environment.dart';

/// Fixed timestamp used across tests for determinism.
final testTime = DateTime.utc(2026, 1, 2, 3, 4, 5);

ExecutionEnvironment windowsEnv({String id = 'windows'}) =>
    ExecutionEnvironment(
      id: id,
      kind: EnvironmentKind.windowsNative,
      name: 'Windows',
      createdAt: testTime,
    );

/// The local macOS/Linux host, for the cases that are about a POSIX desktop
/// rather than about Windows.
ExecutionEnvironment posixEnv({String id = 'windows', String name = 'macOS'}) =>
    ExecutionEnvironment(
      id: id,
      kind: EnvironmentKind.localPosix,
      name: name,
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

ExecutionEnvironment sshEnvFixture({
  String id = 'ssh:h1',
  String hostId = 'h1',
  String name = 'build-box',
}) => ExecutionEnvironment(
  id: id,
  kind: EnvironmentKind.ssh,
  name: name,
  sshHostId: hostId,
  createdAt: testTime,
);

AgentInstallation agentInstallation({
  String id = 'a1',
  String agentId = AgentIds.claudeCode,
  String environmentId = 'windows',
  String path = r'C:\Users\me\.bin\claude.exe',
  String? version = '1.0.0',
  DateTime? versionReadAt,
}) => AgentInstallation(
  id: id,
  agentId: agentId,
  executable: EnvironmentPath(environmentId: environmentId, path: path),
  version: version,
  versionReadAt: versionReadAt,
  createdAt: testTime,
);

/// A working directory in the local Windows environment — what an
/// `AgentLaunch` carries. The app's fixture builds one out of a `Repository`,
/// which is the host's model and not this package's.
EnvironmentPath workingDirectory({
  String environmentId = 'windows',
  String path = r'C:\src\demo\app',
}) => EnvironmentPath(environmentId: environmentId, path: path);
