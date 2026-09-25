import 'package:agent_cli/process.dart';
import 'package:path/path.dart' as p;
import 'package:riverpod/riverpod.dart';

import '../../environments/application/environment_providers.dart';
import '../../explorer/application/where_you_are.dart';
import '../../repositories/application/repository_providers.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_working_directory.dart';
import 'checkpoint_providers.dart';

/// How many repositories a session checkpointed before are revisited per turn,
/// beyond its own and the ones the turn touched.
const int kCheckpointKnownRepositoryLimit = 8;

/// The working trees a turn of [sessionId] is checkpointed in: its own checkout
/// first, the repositories it checkpointed before, and every repository the
/// agent's tools or working directory named — so a session started in a folder
/// whose projects are nested, ignored clones still checkpoints the clone it
/// edits. Only repositories under the session's own folders, or ones the
/// workspace knows, are taken: a tool that read `/tmp` must not snapshot it.
Future<List<EnvironmentPath>> checkpointTargetsFor(
  Ref ref,
  String sessionId, {
  Iterable<String> touched = const [],
}) async {
  final session = ref.read(sessionDaoProvider).getById(sessionId);
  if (session == null) return const [];
  final primary = checkpointTargetFor(ref, sessionId);
  final repositories = ref.read(repositoryDaoProvider);
  final home = repositories.getById(session.repositoryId)?.path;
  final environmentId = primary?.environmentId ?? home?.environmentId;

  final targets = <EnvironmentPath>[];
  void add(EnvironmentPath path) {
    if (targets.any(
      (t) => t.environmentId == path.environmentId && t.path == path.path,
    )) {
      return;
    }
    targets.add(path);
  }

  if (primary != null) add(primary);
  // A removed worktree stays in the history and is not revisited: its rows
  // are a record, and a capture there can only fail, every turn.
  final present = ref.read(sessionDirectoryPresentProvider);
  final known = ref
      .read(checkpointDaoProvider)
      .repositoriesFor(sessionId)
      .where(present);
  for (final repo in known.take(kCheckpointKnownRepositoryLimit)) {
    add(repo);
  }
  if (environmentId == null) return targets;

  final env = ref.read(executionEnvironmentDaoProvider).getById(environmentId);
  if (env == null) return targets;
  final context = usesWindowsPaths(env.kind) ? p.windows : p.posix;
  final cwd = ref.read(agentWorkingDirectoriesProvider)[sessionId];
  final base = cwd?.environmentId == environmentId
      ? cwd!.path
      : session.workingDirectory?.path ?? primary?.path ?? home?.path;
  final scopes = {?session.workingDirectory?.path, ?primary?.path, ?home?.path};
  final registered = {
    for (final repo in repositories.getAll())
      if (repo.path.environmentId == environmentId) repo.path.path,
  };
  bool inScope(String root) =>
      registered.contains(root) ||
      scopes.any((s) => context.equals(s, root) || context.isWithin(s, root));

  final candidates = [
    ...touched,
    if (cwd != null && cwd.environmentId == environmentId) cwd.path,
  ];
  final service = ref.read(checkpointServiceProvider);
  for (final candidate in candidates) {
    final absolute = context.isAbsolute(candidate) || base == null
        ? candidate
        : context.join(base, candidate);
    final root = await service.repositoryRootOf(
      EnvironmentPath(environmentId: environmentId, path: absolute),
    );
    if (root == null || !inScope(root.path)) continue;
    add(root);
  }
  return targets;
}
