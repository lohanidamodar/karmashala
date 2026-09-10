import 'package:riverpod/riverpod.dart';

import '../../cli_detection/application/cli_detection_providers.dart';
import 'package:agent_cli/read.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_git/git.dart';
import '../../repositories/application/repository_providers.dart';
import 'package:karmashala_git/repositories.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_signals.dart';
import '../../sessions/domain/session.dart';
import 'checkout.dart';

/// One linked worktree of a repository, as the Explorer draws it.
class WorktreeNode {
  const WorktreeNode({
    required this.worktree,
    required this.owner,
    this.repository,
  });

  /// What `git worktree list` said: the path, and the branch checked out in it.
  final GitWorktree worktree;

  /// The repository this is a worktree *of* — the main checkout.
  final Repository owner;

  /// The workspace `repositories` row at this exact location, when discovery
  /// found one — the difference between a worktree we can only *describe* and
  /// one we can start a session in, which needs a repository id.
  final Repository? repository;

  /// Where this worktree is, preferring the spelling the workspace stores so
  /// the stat provider's family key lands on the cards' entry (see [Checkout]).
  EnvironmentPath get path => repository?.path ?? worktree.path;

  String? get branch => worktree.branch;

  /// Whether a session can be started here in one click.
  bool get startable => repository != null;
}

/// One repository of a project, with the worktrees hanging off it.
class RepoNode {
  const RepoNode({
    required this.repository,
    this.worktrees = const [],
    this.worktreesKnown = true,
  });

  final Repository repository;

  /// Linked worktrees only — never the main checkout, which *is* [repository].
  final List<WorktreeNode> worktrees;

  /// Whether git actually answered. False means "we could not ask", which is a
  /// different fact from "there are no worktrees" and must not be drawn as one.
  final bool worktreesKnown;
}

/// A project's repositories, with the ones that are really worktrees of another
/// folded underneath: discovery calls any folder with a `.git` entry a
/// repository, so a clone plus five `wt-*` folders listed as six siblings.
class ProjectTree {
  const ProjectTree({required this.repositories});

  static const empty = ProjectTree(repositories: []);

  final List<RepoNode> repositories;

  /// The node a session with [repositoryId] and [worktree] belongs on. Nothing
  /// is ever dropped: an unlisted worktree falls back to its repository's row.
  ({RepoNode repo, WorktreeNode? worktree})? locate({
    required String repositoryId,
    EnvironmentPath? worktree,
  }) {
    for (final node in repositories) {
      if (node.repository.id == repositoryId) {
        if (worktree == null) return (repo: node, worktree: null);
        for (final child in node.worktrees) {
          if (samePath(child.path.path, worktree.path)) {
            return (repo: node, worktree: child);
          }
        }
        return (repo: node, worktree: null);
      }
      for (final child in node.worktrees) {
        if (child.repository?.id == repositoryId) {
          return (repo: node, worktree: child);
        }
      }
    }
    return null;
  }
}

/// The sessions that live in one place — a repository's main checkout, one of
/// its worktrees, or a folder the scanner has not been to yet.
class CheckoutSessions {
  const CheckoutSessions({this.native = const [], this.imported = const []});

  static const none = CheckoutSessions();

  final List<Session> native;
  final List<ImportedSession> imported;

  int get length => native.length + imported.length;
  bool get isEmpty => native.isEmpty && imported.isEmpty;
}

/// A directory a session works in that has no repository row. Rendered, never
/// persisted: inserting a row here would be the UI guessing at the scanner's
/// job, so the row says "not scanned yet" and offers the rescan.
class UnscannedNode {
  const UnscannedNode({required this.path, required this.label});

  final EnvironmentPath path;

  /// How the row reads: the path relative to the row it hangs under.
  final String label;
}

/// The key a row is addressed by in a [SessionPlacement].
String repoRowKey(Repository repository) => 'repo:${repository.id}';
String worktreeRowKey(EnvironmentPath path) =>
    'wt:${canonicalPathKey(path.path)}';
String folderRowKey(EnvironmentPath path) =>
    'dir:${canonicalPathKey(path.path)}';

/// Which row each session is drawn on.
class SessionPlacement {
  const SessionPlacement({this.onRow = const {}, this.foldersUnder = const {}});

  static const empty = SessionPlacement();

  /// Row key → the sessions drawn directly on that row.
  final Map<String, CheckoutSessions> onRow;

  /// Row key → unscanned folders discovered beneath it, shallowest first.
  final Map<String, List<UnscannedNode>> foldersUnder;

  CheckoutSessions at(String rowKey) => onRow[rowKey] ?? CheckoutSessions.none;
  List<UnscannedNode> under(String rowKey) => foldersUnder[rowKey] ?? const [];
}

/// One session, reduced to the two facts placement needs.
class SessionLocation {
  const SessionLocation({
    required this.repositoryId,
    required this.directory,
    this.native,
    this.imported,
  });

  final String repositoryId;

  /// Where the agent is actually working — the reason placement is not a plain
  /// `repositoryId` lookup, which piles a hub's dozen sessions into one row.
  final EnvironmentPath directory;

  final Session? native;
  final ImportedSession? imported;
}

/// Places every session on the deepest row whose path contains it, inserting an
/// [UnscannedNode] when that row is not the directory itself. Nothing is ever
/// dropped: an uncontained session falls back to its own repository row.
SessionPlacement placeSessions(
  ProjectTree tree,
  List<SessionLocation> sessions,
) {
  if (tree.repositories.isEmpty) return SessionPlacement.empty;

  // Every row that can hold a session, with the path it stands for.
  final rows = <({String key, EnvironmentPath path})>[];
  final rowForRepositoryId = <String, String>{};
  for (final node in tree.repositories) {
    rows.add((key: repoRowKey(node.repository), path: node.repository.path));
    rowForRepositoryId[node.repository.id] = repoRowKey(node.repository);
    for (final child in node.worktrees) {
      rows.add((key: worktreeRowKey(child.path), path: child.path));
      final id = child.repository?.id;
      if (id != null) rowForRepositoryId[id] = worktreeRowKey(child.path);
    }
  }

  final native = <String, List<Session>>{};
  final imported = <String, List<ImportedSession>>{};
  final folders = <String, Map<String, UnscannedNode>>{};

  for (final session in sessions) {
    ({String key, EnvironmentPath path})? best;
    for (final row in rows) {
      if (!isUnder(row.path, session.directory)) continue;
      if (best == null || pathDepth(row.path) > pathDepth(best.path)) {
        best = row;
      }
    }

    var key = best?.key ?? rowForRepositoryId[session.repositoryId];
    if (best != null && !samePath(best.path.path, session.directory.path)) {
      final label =
          relativeSubPath(best.path, session.directory) ??
          session.directory.path;
      key = folderRowKey(session.directory);
      (folders[best.key] ??= {})[key] = UnscannedNode(
        path: session.directory,
        label: label,
      );
    }
    key ??= rows.first.key;

    final row = session.native;
    if (row != null) {
      (native[key] ??= []).add(row);
    } else if (session.imported != null) {
      (imported[key] ??= []).add(session.imported!);
    }
  }

  return SessionPlacement(
    onRow: {
      for (final key in {...native.keys, ...imported.keys})
        key: CheckoutSessions(
          native: native[key] ?? const [],
          imported: imported[key] ?? const [],
        ),
    },
    foldersUnder: {
      for (final entry in folders.entries)
        entry.key: entry.value.values.toList()
          ..sort((a, b) => a.label.compareTo(b.label)),
    },
  );
}

/// Every session under one project, reduced to where its agent works. There is
/// no `cwd` column and none is needed: a session's directory is the worktree it
/// recorded or its repository's path, which is what the launcher passed.
final projectSessionLocationsProvider = Provider.autoDispose
    .family<List<SessionLocation>, String>((ref, projectId) {
      // The tree draws each session's name and status under its directory, so
      // almost everything about a row reaches here — but not a permission mode.
      ref.watchSessionKinds(const {
        SessionChangeKind.membership,
        SessionChangeKind.title,
        SessionChangeKind.status,
        SessionChangeKind.placement,
        SessionChangeKind.workspace,
      });
      final repositoryDao = ref.read(repositoryDaoProvider);
      final sessionDao = ref.read(sessionDaoProvider);
      final importedDao = ref.read(importedSessionDaoProvider);

      final locations = <SessionLocation>[];
      for (final repo in repositoryDao.getByProject(projectId)) {
        for (final session in sessionDao.getByRepository(repo.id)) {
          locations.add(
            SessionLocation(
              repositoryId: repo.id,
              directory: session.worktree ?? repo.path,
              native: session,
            ),
          );
        }
        for (final session in importedDao.getByRepository(repo.id)) {
          locations.add(
            SessionLocation(
              repositoryId: repo.id,
              directory: repo.path,
              imported: session,
            ),
          );
        }
      }
      return locations;
    });

/// Every session in a project, which is all the Explorer draws under a project
/// header. A row per checkout, each watching git, cost 414 subprocesses to draw
/// thirteen rows at 69 checkouts (`checkout_scale_cost_test.dart`).
final projectSessionsProvider = Provider.autoDispose
    .family<CheckoutSessions, String>((ref, projectId) {
      final locations = ref.watch(projectSessionLocationsProvider(projectId));
      return CheckoutSessions(
        native: [for (final location in locations) ?location.native],
        imported: [for (final location in locations) ?location.imported],
      );
    });
