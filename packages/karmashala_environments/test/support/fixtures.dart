import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';

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
  bool executableByUser = false,
}) => AgentInstallation(
  id: id,
  agentId: agentId,
  executable: EnvironmentPath(environmentId: environmentId, path: path),
  version: version,
  versionReadAt: versionReadAt,
  executableByUser: executableByUser,
  createdAt: testTime,
);
