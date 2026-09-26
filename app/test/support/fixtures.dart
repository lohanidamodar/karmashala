import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala/src/core/data/data_providers.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_projects/karmashala_projects.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session/events.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/data/data_client.dart';
import 'package:karmashala/src/features/workspaces/application/workspaces_controller.dart';
import 'package:karmashala/src/features/workspaces/data/workspace_data.dart';

/// Fixed timestamp used across tests for determinism.
final testTime = DateTime.utc(2026, 1, 2, 3, 4, 5);

/// The app's copy of the workspace over [db], for a service built outside a
/// container. The one place a test reaches the workspace through [db].
WorkspaceData workspaceOver(AppDatabase db) =>
    WorkspaceData(DataClient.inProcess(db));

/// A context made through [container]'s own controller, as its copy now
/// holds it — for a test that needs it before it can wait.
Workspace createContext(
  ProviderContainer container,
  String name, {
  String? description,
}) {
  unawaited(
    container
        .read(workspacesControllerProvider.notifier)
        .create(name, description: description),
  );
  return container
      .read(workspacesControllerProvider)
      .singleWhere((w) => w.name == name);
}

/// After a test wrote the workspace tables itself, [container]'s copy of the
/// workspace reads them again.
void rereadWorkspace(ProviderContainer container) =>
    unawaited(container.read(dataClientProvider).resync(DataDomain.workspace));

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

Project project({
  String id = 'p1',
  String name = 'Demo',
  String environmentId = 'windows',
  String path = r'C:\src\demo',
  String? workspaceId,
}) => Project(
  id: id,
  name: name,
  root: EnvironmentPath(environmentId: environmentId, path: path),
  workspaceId: workspaceId,
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
  DateTime? versionReadAt,
}) => AgentInstallation(
  id: id,
  agentId: agentId,
  executable: EnvironmentPath(environmentId: environmentId, path: path),
  version: version,
  versionReadAt: versionReadAt,
  createdAt: testTime,
);

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

/// One `git status --porcelain=v2 --branch` reply, which is what the app asks
/// for and therefore the only status text a fixture should pin.
///
/// Spelling v2 out by hand is nine fields per file, most of them shas nothing
/// reads, so it is built here once. What the callers actually vary is on the
/// signature: the branch, its upstream, the distance between them, and which
/// files changed how.
///
/// [ahead] and [behind] default to zero rather than null because that is what
/// having an upstream at parity means, and v2 says so out loud (`# branch.ab
/// +0 -0`) where v1 said it by printing nothing. Pass null for either to leave
/// the header out, which is what git does when it **cannot** compute the
/// distance — a branch with no upstream, or an upstream that has gone from the
/// remote.
String porcelainV2({
  String? branch = 'main',
  String? upstream,
  int? ahead = 0,
  int? behind = 0,
  List<String> modified = const [],
  List<String> staged = const [],
  List<String> untracked = const [],
  List<String> unmerged = const [],
  Map<String, String> renamed = const {},
  bool initial = false,
}) {
  const sha = '0000000000000000000000000000000000000000';
  const modes = '100644 100644 100644';
  return [
    '# branch.oid ${initial ? '(initial)' : 'f1e2d3c4b5a69788f1e2d3c4b5a69788f1e2d3c4'}',
    '# branch.head ${branch ?? '(detached)'}',
    if (upstream != null) '# branch.upstream $upstream',
    if (upstream != null && ahead != null && behind != null)
      '# branch.ab +$ahead -$behind',
    for (final path in staged) '1 M. N... $modes $sha $sha $path',
    for (final path in modified) '1 .M N... $modes $sha $sha $path',
    // `<path>\t<origPath>`, tab-separated, which is the shape v1 never writes.
    for (final entry in renamed.entries)
      '2 R. N... $modes $sha $sha R100 ${entry.key}\t${entry.value}',
    // An unmerged path is its own record type in v2, where v1 wrote `UU`.
    for (final path in unmerged)
      'u UU N... 100644 100644 100644 100644 $sha $sha $sha $path',
    for (final path in untracked) '? $path',
    '',
  ].join('\n');
}
