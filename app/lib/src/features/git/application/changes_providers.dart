import '../../workspaces/data/workspace_data.dart';
import 'package:riverpod/riverpod.dart';

import '../../../app/shell/quick_open/repo_file_index.dart';
import '../../../core/process/command_runner_providers.dart';
import '../../editor/application/code_editor_providers.dart';
import '../../environments/application/environment_providers.dart';
import '../../environments/application/environment_resolver.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_git/repositories.dart';
import '../../projects/application/projects_controller.dart';
import 'package:karmashala_git/git.dart';
import 'changes_service.dart';
import 'git_providers.dart';

/// The filesystem `ChangesService.originFacts` and `GitPresenceReader` read
/// `.git` through; a provider only so a test can count reads without a disk.
final gitFilesProvider = Provider<GitFiles>((ref) => const HostGitFiles());

final changesServiceProvider = Provider<ChangesService>(
  (ref) => ChangesService(
    runnerFactory: ref.watch(commandRunnerFactoryProvider),
    environmentDao: ref.watch(executionEnvironmentDaoProvider),
    files: ref.watch(gitFilesProvider),
    // The watcher sees a merge's in-place rewrites only where it is recursive
    // and the root is watched at all.
    onWorkingTreeChanged: (repo) {
      final root = ref.read(editorActionsProvider).windowsPathFor(repo);
      if (root != null) ref.read(repoFileIndexProvider).touch(root);
    },
  ),
);

/// The repository whose changes are being reviewed, or `null`.
class SelectedRepositoryController extends Notifier<String?> {
  @override
  String? build() => null;
  void select(String? id) => state = id;
}

final selectedRepositoryIdProvider =
    NotifierProvider<SelectedRepositoryController, String?>(
      SelectedRepositoryController.new,
    );

/// The selected repository row. Watch this, not the repository list, whose
/// every announcement reaches every watcher (a `List` is never `==`) and threw
/// `markNeedsBuild() called during build` from a sibling.
final selectedRepositoryProvider = Provider<Repository?>((ref) {
  final id = ref.watch(selectedRepositoryIdProvider);
  if (id == null) return null;
  return ref
      .watch(selectedProjectRepositoriesProvider)
      .where((r) => r.id == id)
      .firstOrNull;
});

/// A worktree the user is *reading*, filed against the checkout it was picked
/// under: browsing writes no session row or working directory, so it can never
/// move where the next agent launches.
class WorktreeBrowse {
  const WorktreeBrowse({
    required this.repositoryId,
    required this.path,
    this.branch,
  });

  /// The `repositories` row selected when this pick was made.
  final String repositoryId;

  final EnvironmentPath path;

  /// Null when the worktree is detached; then the folder name is the label.
  final String? branch;

  String get label => branch ?? lastPathSegment(path.path);
}

/// Which worktree the change-reading surfaces are pointed at, or null for the
/// selected checkout's own directory.
class WorktreeBrowsing extends Notifier<WorktreeBrowse?> {
  @override
  WorktreeBrowse? build() => null;

  void browse(WorktreeBrowse pick) => state = pick;
  void stop() => state = null;
}

final worktreeBrowsingProvider =
    NotifierProvider<WorktreeBrowsing, WorktreeBrowse?>(WorktreeBrowsing.new);

/// The selected checkout's own directory — where the panes read when nothing
/// is being browsed, and the row a picker returns to.
final selectedCheckoutPathProvider = Provider.autoDispose<EnvironmentPath?>((
  ref,
) {
  final id = ref.watch(selectedRepositoryIdProvider);
  if (id == null) return null;
  return ref.read(workspaceDataProvider).repository(id)?.path;
});

/// The repository row whose working tree is [checkout], or null when no row
/// names it — a browsed worktree has none of its own.
final repositoryIdForCheckoutProvider = Provider.autoDispose
    .family<String?, EnvironmentPath>(
      (ref, checkout) => ref
          .read(workspaceDataProvider)
          .repositoriesAt(checkout)
          .firstOrNull
          ?.id,
    );

/// The browse that still applies: null while another checkout is selected, so a
/// pick made under one never describes another.
final browsedWorktreeProvider = Provider.autoDispose<WorktreeBrowse?>((ref) {
  final pick = ref.watch(worktreeBrowsingProvider);
  if (pick == null) return null;
  return pick.repositoryId == ref.watch(selectedRepositoryIdProvider)
      ? pick
      : null;
});

/// Whether the browsed worktree has since been removed. False while the listing
/// is loading or failed: "we have not been told" is not "it is gone".
final browsedWorktreeMissingProvider = Provider.autoDispose<bool>((ref) {
  final pick = ref.watch(browsedWorktreeProvider);
  if (pick == null) return false;
  final listed = ref.watch(repoWorktreesProvider).asData?.value;
  if (listed == null) return false;
  return !listed.any((w) => Checkout(w.path) == Checkout(pick.path));
});

/// The working tree the change-reading providers read: the browsed worktree,
/// falling back to the selected checkout once that worktree has been removed.
final viewedCheckoutProvider = Provider.autoDispose<EnvironmentPath?>((ref) {
  final home = ref.watch(selectedCheckoutPathProvider);
  if (home == null) return null;
  final pick = ref.watch(browsedWorktreeProvider);
  if (pick == null) return home;
  return ref.watch(browsedWorktreeMissingProvider) ? home : pick.path;
});

/// Whether a checkout is under git, spawning nothing. Keyed by the checkout and
/// not the repository row: the Repository and Changes panes diverge the moment
/// the picker moves.
final checkoutGitPresenceProvider = FutureProvider.autoDispose
    .family<GitPresence, EnvironmentPath>((ref, checkout) async {
      final env = ref
          .read(environmentResolverProvider)
          .resolveFor(checkout)
          .environment;
      // No environment row is not a statement about the folder.
      if (env == null) return GitPresence.unknown;
      return GitPresenceReader(
        files: ref.watch(gitFilesProvider),
        hostPathOf: hostPathMapperFor(env),
      ).read(checkout.path);
    });

/// Throws [NotAGitRepository] when the filesystem already said [checkout] is not
/// under version control. Every caller must `ref.read` its service *before*
/// awaiting this: a read after an await throws on a `Ref` disposed in the gap.
Future<void> _requireRepository(Ref ref, EnvironmentPath checkout) async {
  final presence = await ref.watch(
    checkoutGitPresenceProvider(checkout).future,
  );
  if (presence == GitPresence.notARepository) {
    throw NotAGitRepository(checkout);
  }
}

/// Ask git again only where asking again could change the answer: the default
/// policy spends 38 s over ten attempts, so only a real failure (a contended
/// index lock) keeps it.
Duration? _retryOnlyRealFailures(int count, Object error) =>
    gitTroubleOf(error) == GitTrouble.failed
    ? ProviderContainer.defaultRetry(count, error)
    : null;

/// Working-tree changes for the checkout being viewed.
final repositoryChangesProvider = FutureProvider.autoDispose<List<FileChange>>((
  ref,
) async {
  final path = ref.watch(viewedCheckoutProvider);
  if (path == null) return const [];
  final changes = ref.read(changesServiceProvider);
  await _requireRepository(ref, path);
  return changes.changes(path);
}, retry: _retryOnlyRealFailures);

/// Lines added and removed per file in the checkout being viewed. One `git
/// diff --numstat` for the whole listing rather than one per row. A path that
/// is absent was not reported — an untracked file never is.
final repositoryFileDiffStatsProvider =
    FutureProvider.autoDispose<Map<String, FileDiffStat>>((ref) async {
      final path = ref.watch(viewedCheckoutProvider);
      if (path == null) return const {};
      final changes = ref.read(changesServiceProvider);
      await _requireRepository(ref, path);
      return changes.fileDiffStats(path);
    }, retry: _retryOnlyRealFailures);

/// Whether there is a merge to abort in the checkout being viewed. A conflicted
/// row *is* an unfinished merge, so only an all-resolved-but-uncommitted tree
/// costs a `.git/MERGE_HEAD` stat.
final mergeInProgressProvider = FutureProvider.autoDispose<bool>((ref) async {
  final listing = ref.watch(repositoryChangesProvider.future);
  final List<FileChange> changes;
  try {
    changes = await listing;
  } on Object {
    // Swallowed rather than rethrown so this does not inherit the listing's
    // retry, whose backoff timer would outlive the pane.
    return false;
  }
  // A clean tree is not a merge: a stopped merge always leaves something in the
  // listing, staged or not.
  if (changes.isEmpty) return false;
  if (changes.any((c) => c.type == FileChangeType.conflicted)) return true;
  final path = ref.read(viewedCheckoutProvider);
  if (path == null) return false;
  return await ref.read(changesServiceProvider).mergeInProgress(path) ?? false;
});

/// The branch of the checkout being viewed, its upstream, and how far apart
/// they are — one `git status --porcelain=v2 --branch`, read only while a
/// surface that shows a branch is on screen.
///
/// Separate from [repositoryChangesProvider] on purpose: that one is the file
/// list and repaints per file row, this one is the header, and a stage must
/// not repaint the list to move an "ahead" count.
final workingTreeStatusProvider = FutureProvider.autoDispose<WorkingTreeStatus>(
  (ref) async {
    final path = ref.watch(viewedCheckoutProvider);
    if (path == null) return WorkingTreeStatus.unknown;
    await _requireRepository(ref, path);
    return ref.read(changesServiceProvider).statusWithBranch(path);
  },
  retry: _retryOnlyRealFailures,
);

/// The current branch of the selected repository.
final currentBranchProvider = FutureProvider.autoDispose<String?>((ref) async {
  final id = ref.watch(selectedRepositoryIdProvider);
  if (id == null) return null;
  final repo = ref.read(workspaceDataProvider).repository(id);
  if (repo == null) return null;
  final changes = ref.read(changesServiceProvider);
  // A folder with no git in it is not a *detached* checkout, which is what this
  // provider's null means.
  await _requireRepository(ref, repo.path);
  return changes.currentBranch(repo.path);
}, retry: _retryOnlyRealFailures);

/// The `origin` remote URL of the selected repository.
final repoRemoteUrlProvider = FutureProvider.autoDispose<String?>((ref) async {
  final id = ref.watch(selectedRepositoryIdProvider);
  if (id == null) return null;
  final repo = ref.read(workspaceDataProvider).repository(id);
  if (repo == null) return null;
  final changes = ref.read(changesServiceProvider);
  // Likewise: null here is "a clone with no `origin`", not a folder that was
  // never cloned.
  await _requireRepository(ref, repo.path);
  return changes.remoteUrl(repo.path);
}, retry: _retryOnlyRealFailures);

/// Recent commits on the branch the viewed checkout has out — follows the
/// browse, unlike the branch and remote above, which the status bar reads.
final recentCommitsProvider = FutureProvider.autoDispose<List<GitCommit>>((
  ref,
) async {
  final path = ref.watch(viewedCheckoutProvider);
  if (path == null) return const [];
  final changes = ref.read(changesServiceProvider);
  await _requireRepository(ref, path);
  return changes.log(path, limit: 8);
}, retry: _retryOnlyRealFailures);

/// The worktrees of the *selected* checkout, not the viewed one: asking the
/// browsed worktree would fail exactly when it has just been removed.
final repoWorktreesProvider = FutureProvider.autoDispose<List<GitWorktree>>((
  ref,
) async {
  final id = ref.watch(selectedRepositoryIdProvider);
  if (id == null) return const [];
  final repo = ref.read(workspaceDataProvider).repository(id);
  if (repo == null) return const [];
  final worktrees = ref.read(worktreeServiceProvider);
  // Empty here is "one working tree and no others", drawn as `none`. A folder
  // that is not a repository has neither.
  await _requireRepository(ref, repo.path);
  return worktrees.list(repo.path);
}, retry: _retryOnlyRealFailures);

/// One verdict for the whole GIT section, null while it still has facts —
/// including while finding out. Read off [repoWorktreesProvider] because
/// [currentBranchProvider] folds a failure into the null it uses for "detached".
final selectedCheckoutGitTroubleProvider = Provider.autoDispose<GitTroubleReport?>((
  ref,
) {
  final checkout = ref.watch(selectedCheckoutPathProvider);
  if (checkout == null) return null;
  if (ref.watch(checkoutGitPresenceProvider(checkout)).asData?.value ==
      GitPresence.notARepository) {
    return const GitTroubleReport(GitTrouble.notARepository);
  }
  // `.error`, not an `AsyncError` pattern: a failure Riverpod is still retrying
  // is an `AsyncLoading` carrying its error, and must not go quiet for backoff.
  final error = ref.watch(repoWorktreesProvider).error;
  if (error == null) return null;
  return switch (gitTroubleOf(error)) {
    // git's own text helps only for a real failure; the app words the rest.
    GitTrouble.failed => GitTroubleReport(GitTrouble.failed, detail: '$error'),
    final trouble => GitTroubleReport(trouble),
  };
});
