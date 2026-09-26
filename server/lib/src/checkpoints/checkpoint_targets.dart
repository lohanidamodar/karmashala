import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:karmashala_checkpoints/checkpoints.dart';
import 'package:karmashala_checkpoints/store.dart';
import 'package:karmashala_environments/store.dart';
import 'package:karmashala_projects/store.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:path/path.dart' as p;

/// How many repositories a session checkpointed before are revisited per turn,
/// beyond its own and the ones the turn touched.
const int kCheckpointKnownRepositoryLimit = 8;

/// Which working trees a session's turn is checkpointed in, read from the
/// server's store — the rule the app's recorder applied, over the rows the
/// server keeps.
class ServerCheckpointTargets {
  ServerCheckpointTargets({
    required this.sessions,
    required this.repositories,
    required this.environments,
    required this.checkpoints,
    required this.service,
    bool Function(EnvironmentPath directory)? present,
  }) : _present = present;

  final SessionDao sessions;
  final RepositoryDao repositories;
  final ExecutionEnvironmentDao environments;
  final CheckpointDao checkpoints;
  final CheckpointService service;
  final bool Function(EnvironmentPath directory)? _present;

  /// The working tree [session]'s checkpoints are taken of: its worktree, else
  /// its repository's checkout. Null when that is gone — a reason not to
  /// checkpoint, not an error.
  EnvironmentPath? primaryOf(Session session) =>
      session.worktree ?? repositories.getById(session.repositoryId)?.path;

  /// The working trees a turn of [sessionId] is checkpointed in: its own
  /// checkout first, the repositories it checkpointed before, and every
  /// repository the agent's tools ([touched]) or working directory ([cwd])
  /// named — so a session started in a folder whose projects are nested,
  /// ignored clones still checkpoints the clone it edits. Only repositories
  /// under the session's own folders, or ones the workspace knows, are taken:
  /// a tool that read `/tmp` must not snapshot it.
  Future<List<EnvironmentPath>> of(
    String sessionId, {
    Iterable<String> touched = const [],
    String? cwd,
  }) async {
    final session = sessions.getById(sessionId);
    if (session == null) return const [];
    final primary = primaryOf(session);
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
    final known = checkpointRepositoriesIn(
      checkpoints.forSession(sessionId),
    ).where(present);
    for (final repo in known.take(kCheckpointKnownRepositoryLimit)) {
      add(repo);
    }
    if (environmentId == null) return targets;

    final env = environments.getById(environmentId);
    if (env == null) return targets;
    final context = usesWindowsPaths(env.kind) ? p.windows : p.posix;
    // The agent's directory is reported in the environment of its session's
    // own checkout, which is this one only when the two agree.
    final cwdHere = cwd != null && home?.environmentId == environmentId
        ? cwd
        : null;
    final base =
        cwdHere ??
        session.workingDirectory?.path ??
        primary?.path ??
        home?.path;
    final scopes = {
      ?session.workingDirectory?.path,
      ?primary?.path,
      ?home?.path,
    };
    final registered = {
      for (final repo in repositories.getAll())
        if (repo.path.environmentId == environmentId) repo.path.path,
    };
    bool inScope(String root) =>
        registered.contains(root) ||
        scopes.any((s) => context.equals(s, root) || context.isWithin(s, root));

    final candidates = [...touched, ?cwdHere];
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

  /// Whether [directory] is still there, from this machine. A directory this
  /// process cannot look at (SSH, an unknown environment) is assumed present.
  bool present(EnvironmentPath directory) {
    final given = _present;
    if (given != null) return given(directory);
    try {
      final env = environments.getById(directory.environmentId);
      if (env == null) return true;
      var resolved = directory.path;
      if (!isLocalHost(env.kind)) {
        if (env.kind != EnvironmentKind.wsl) return true;
        ExecutionEnvironment? windows;
        for (final candidate in environments.getAll()) {
          if (candidate.kind == EnvironmentKind.windowsNative) {
            windows = candidate;
            break;
          }
        }
        if (windows == null) return true;
        resolved = const PathTranslator()
            .translate(directory, from: env, to: windows)
            .path;
      }
      return Directory(resolved).existsSync();
    } on Object {
      return true;
    }
  }
}
