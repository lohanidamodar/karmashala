import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../cli_detection/application/cli_detection_providers.dart';
import '../../cli_detection/domain/imported_session.dart';
import '../../environments/domain/environment_path.dart';
import '../../git/application/git_providers.dart';
import '../../git/domain/git_worktree.dart';
import '../../repositories/application/repository_providers.dart';
import '../../repositories/domain/repository.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_ui_providers.dart';
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
  /// found one.
  ///
  /// This is the difference between a worktree we can only *describe* and one we
  /// can start a session in: a session needs a repository id, and a folder with
  /// no row has none. Chitragupta's own workspace has both kinds — the sibling
  /// `wt-*` folders under a project root are discovered and get rows, while a
  /// worktree created outside the project folder does not.
  final Repository? repository;

  /// Where this worktree is, preferring the spelling the workspace already
  /// stores so the stat provider's family key lands on the same entry the
  /// session cards inside use. (Both spell the same directory; see [Checkout].)
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

  /// Whether git actually answered. False means "we could not ask" (no git, a
  /// folder that is not a repository, a `.git` file written by another
  /// environment's git — see Loop 50 §8.4), which is a different fact from
  /// "there are no worktrees" and must not be drawn as one.
  final bool worktreesKnown;
}

/// A project's repositories, with the ones that are really worktrees of another
/// folded underneath it.
///
/// **Why the folding matters.** `RepositoryDiscoveryService` calls any folder
/// with a `.git` entry a repository, and a linked worktree has one (a `.git`
/// *file*). So a project whose root holds a clone and five `wt-*` worktree
/// folders — which is exactly the shape of the workspace this app is built in —
/// listed six sibling "repositories" that are one repository with five
/// checkouts. Nothing in the tree said they were related, which is the thing the
/// owner asked to be able to see.
///
/// **What it costs.** One `git worktree list` per repository row, run once when
/// a project is expanded and then cached by Riverpod. It is the only git this
/// provider runs: branches and change counts come from `checkoutStatProvider`,
/// which the rows share with the cards under them.
class ProjectTree {
  const ProjectTree({required this.repositories});

  static const empty = ProjectTree(repositories: []);

  final List<RepoNode> repositories;

  /// The node whose repository row or worktree row a session with
  /// [repositoryId] and [worktree] belongs on.
  ///
  /// A session is never dropped: one pointing at a worktree git no longer lists
  /// (removed, or created by another environment's git) falls back to its
  /// repository's own row rather than vanishing from the tree.
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

/// Builds [ProjectTree] for one project. Lazy by construction: nothing here runs
/// until a project header is expanded and something watches it.
final projectTreeProvider = FutureProvider.autoDispose
    .family<ProjectTree, String>((ref, projectId) async {
      ref.watch(sessionsRevisionProvider);
      final repositories = ref
          .read(repositoryDaoProvider)
          .getByProject(projectId);
      if (repositories.isEmpty) return ProjectTree.empty;

      final service = ref.read(worktreeServiceProvider);
      // Each failure is local: one unreadable repository — no git, a folder
      // that is not a checkout, a `.git` file another environment's git wrote —
      // must not cost the project its whole tree.
      Future<List<GitWorktree>?> listOrNull(Repository repo) async {
        try {
          return await service.list(repo.path);
        } catch (_) {
          return null;
        }
      }

      final lists = await Future.wait(repositories.map(listOrNull));
      return buildProjectTree(repositories, lists);
    });

/// The pure half of [projectTreeProvider]: given each repository's
/// `git worktree list` (or null where git could not answer), decide which rows
/// are top-level and which are worktrees of another.
///
/// `git worktree list --porcelain` reports the **main** worktree first, so a
/// repository whose own path is not the first entry of its own list is a linked
/// worktree. Its owner is whichever workspace row sits at that first entry; a
/// worktree whose main checkout is not in the workspace stays a top-level row,
/// because hiding a folder the user can see is worse than listing it twice.
ProjectTree buildProjectTree(
  List<Repository> repositories,
  List<List<GitWorktree>?> lists,
) {
  final byPath = <String, Repository>{
    for (final repo in repositories) canonicalPathKey(repo.path.path): repo,
  };

  // repository id -> the row it is a linked worktree of.
  final ownerOf = <String, Repository>{};
  for (var i = 0; i < repositories.length; i++) {
    final repo = repositories[i];
    final list = lists[i];
    if (list == null || list.isEmpty) continue;
    final main = list.first;
    if (samePath(main.path.path, repo.path.path)) continue;
    final owner = byPath[canonicalPathKey(main.path.path)];
    if (owner != null && owner.id != repo.id) ownerOf[repo.id] = owner;
  }

  final nodes = <RepoNode>[];
  for (var i = 0; i < repositories.length; i++) {
    final repo = repositories[i];
    if (ownerOf.containsKey(repo.id)) continue;
    final list = lists[i];
    nodes.add(
      RepoNode(
        repository: repo,
        worktreesKnown: list != null,
        worktrees: [
          for (final worktree in (list ?? const <GitWorktree>[]).skip(1))
            if (!worktree.isBare)
              WorktreeNode(
                worktree: worktree,
                owner: repo,
                repository: byPath[canonicalPathKey(worktree.path.path)],
              ),
        ],
      ),
    );
  }
  return ProjectTree(repositories: nodes);
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

/// A directory a session is working in that the workspace has no repository row
/// for.
///
/// Rendered, never persisted. Inserting a `repositories` row from a tree would
/// be the UI guessing at the scanner's job — and guessing wrong for every
/// sub-folder of a repository that is not itself a checkout. So the row says
/// what it is ("not scanned yet") and offers the rescan that would make it real.
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

  /// **Where the agent is actually working.** The one input that matters, and
  /// the reason placement is not just a `repositoryId` lookup: a hub project
  /// with a dozen repositories underneath it has a dozen sessions that each
  /// know their own sub-directory, and a tree that groups them by the row they
  /// were imported against puts all twelve in one pile.
  final EnvironmentPath directory;

  final Session? native;
  final ImportedSession? imported;
}

/// Places every session of a project on the deepest row that contains it.
///
/// The rules, in order:
///
/// 1. The deepest repository or worktree row whose path is a prefix of the
///    session's directory wins. A session in `hub/projects/app` lands on the
///    `app` row, not on `hub`, even though both contain it.
/// 2. When that row's path is not the directory itself, an [UnscannedNode] is
///    drawn between them and the session goes there — a nested checkout the
///    scanner has not recorded yet still nests correctly instead of being
///    dumped at the project root.
/// 3. A session no row contains at all — a different environment, a folder
///    outside the project — falls back to its own `repositoryId` row, and
///    failing that to the first row. **Nothing is ever dropped:** a session
///    drawn a level too high is a nuisance; a session drawn nowhere is a lost
///    piece of work.
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

/// Every session under one project, reduced to where its agent works.
///
/// **There is no separate `cwd` column, and none is needed.** A native session's
/// working directory is the worktree it recorded at launch, or its repository's
/// path — that is literally what `SessionLauncher.launch` passes as the process
/// working directory. An imported session's is its repository's path too,
/// because `SessionAutoImportService` binds a CLI session to a repository only
/// when the repository's canonical path *equals* the cwd the CLI recorded. So
/// the repository row a session points at is the recorded cwd, and reading it
/// here keeps one source of truth rather than a second, staler copy.
final projectSessionLocationsProvider = Provider.autoDispose
    .family<List<SessionLocation>, String>((ref, projectId) {
      ref.watch(sessionsRevisionProvider);
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

/// The tree and the sessions on it, which is everything a project's rows need.
///
/// The tree half is asynchronous (it asks git about worktrees); the placement
/// half is not. While git is still answering, the repositories are drawn as
/// peers with no worktrees and the sessions are placed on them — so expanding a
/// project shows its contents immediately and the worktrees fold in when the
/// answer lands, rather than the whole subtree appearing late.
final projectTreeViewProvider = Provider.autoDispose
    .family<({ProjectTree tree, SessionPlacement placement}), String>((
      ref,
      projectId,
    ) {
      final tree =
          ref.watch(projectTreeProvider(projectId)).asData?.value ??
          ProjectTree(
            repositories: [
              for (final repo
                  in ref.read(repositoryDaoProvider).getByProject(projectId))
                RepoNode(repository: repo, worktreesKnown: false),
            ],
          );
      final locations = ref.watch(projectSessionLocationsProvider(projectId));
      return (tree: tree, placement: placeSessions(tree, locations));
    });
