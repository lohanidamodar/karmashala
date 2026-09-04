import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/shell/quick_open/repo_file_index.dart';
import '../../../core/process/command_runner_providers.dart';
import '../../editor/application/code_editor_providers.dart';
import '../../environments/application/environment_providers.dart';
import '../../environments/domain/environment_path.dart';
import '../../explorer/application/checkout.dart';
import '../../repositories/application/repository_providers.dart';
import '../data/git_files.dart';
import '../domain/file_change.dart';
import '../domain/git_commit.dart';
import '../domain/git_worktree.dart';
import 'changes_service.dart';
import 'git_providers.dart';

/// The filesystem `ChangesService.originFacts` reads `.git` through.
///
/// A provider so a test can count the reads without a disk — the same reason
/// `commandRunnerFactoryProvider` is one. The app always uses the real
/// filesystem; nothing in it ever sets this.
final gitFilesProvider = Provider<GitFiles>((ref) => const HostGitFiles());

/// Provides the [ChangesService].
final changesServiceProvider = Provider<ChangesService>(
  (ref) => ChangesService(
    runnerFactory: ref.watch(commandRunnerFactoryProvider),
    environmentDao: ref.watch(executionEnvironmentDaoProvider),
    files: ref.watch(gitFilesProvider),
    // A merge rewrites files in place, which the watcher does see — but only on
    // the platforms that have a recursive one, and only for a root that is
    // being watched at all.
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

/// The file within the selected repository whose diff is shown, or `null`.
class SelectedChangeFileController extends Notifier<String?> {
  @override
  String? build() => null;
  void select(String? path) => state = path;
}

final selectedChangeFileProvider =
    NotifierProvider<SelectedChangeFileController, String?>(
      SelectedChangeFileController.new,
    );

/// A worktree the user is **reading**, filed against the checkout it was picked
/// under so it describes nothing while another one is selected.
///
/// Deliberately not a checkout *selection*: `CheckoutPicker` moves the Explorer,
/// the panels and the pick remembered against the followed session, which is
/// where the next agent launches. Browsing writes none of that — no session row,
/// no working directory, nothing `AgentResumeLocality` can read — so comparing
/// two worktrees' diffs cannot move an agent by accident.
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
/// selected checkout's own directory — which is what everyone sees until they
/// touch the picker.
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
  return ref.read(repositoryDaoProvider).getById(id)?.path;
});

/// The browse that still applies: null while another checkout is selected, so a
/// pick made under one can never describe another — and live again if the
/// selection comes back to the checkout it was made under.
final browsedWorktreeProvider = Provider.autoDispose<WorktreeBrowse?>((ref) {
  final pick = ref.watch(worktreeBrowsingProvider);
  if (pick == null) return null;
  return pick.repositoryId == ref.watch(selectedRepositoryIdProvider)
      ? pick
      : null;
});

/// Whether the worktree being browsed has since been removed — agents create
/// and destroy them constantly, and one can vanish while it is on screen.
///
/// False while nothing is browsed (and then nothing here asks git anything) and
/// false while the listing is loading or failed: "we have not been told" is not
/// "it is gone".
final browsedWorktreeMissingProvider = Provider.autoDispose<bool>((ref) {
  final pick = ref.watch(browsedWorktreeProvider);
  if (pick == null) return false;
  final listed = ref.watch(repoWorktreesProvider).asData?.value;
  if (listed == null) return false;
  return !listed.any((w) => Checkout(w.path) == Checkout(pick.path));
});

/// The working tree the change-reading providers below actually read: the
/// browsed worktree, or the selected checkout's own directory.
///
/// A worktree that has been removed falls back to the checkout rather than
/// failing every git call against a directory that is not there;
/// [browsedWorktreeMissingProvider] is what says so on screen.
final viewedCheckoutProvider = Provider.autoDispose<EnvironmentPath?>((ref) {
  final home = ref.watch(selectedCheckoutPathProvider);
  if (home == null) return null;
  final pick = ref.watch(browsedWorktreeProvider);
  if (pick == null) return home;
  return ref.watch(browsedWorktreeMissingProvider) ? home : pick.path;
});

/// Working-tree changes for the checkout being viewed.
final repositoryChangesProvider = FutureProvider.autoDispose<List<FileChange>>((
  ref,
) async {
  final path = ref.watch(viewedCheckoutProvider);
  if (path == null) return const [];
  return ref.read(changesServiceProvider).changes(path);
});

/// The current branch of the selected repository.
final currentBranchProvider = FutureProvider.autoDispose<String?>((ref) async {
  final id = ref.watch(selectedRepositoryIdProvider);
  if (id == null) return null;
  final repo = ref.read(repositoryDaoProvider).getById(id);
  if (repo == null) return null;
  return ref.read(changesServiceProvider).currentBranch(repo.path);
});

/// The `origin` remote URL of the selected repository.
final repoRemoteUrlProvider = FutureProvider.autoDispose<String?>((ref) async {
  final id = ref.watch(selectedRepositoryIdProvider);
  if (id == null) return null;
  final repo = ref.read(repositoryDaoProvider).getById(id);
  if (repo == null) return null;
  return ref.read(changesServiceProvider).remoteUrl(repo.path);
});

/// Recent commits on the branch the viewed checkout has out.
///
/// Follows the browse, unlike [currentBranchProvider] and
/// [repoRemoteUrlProvider] above: those two are read by the status bar and by
/// Quick Open, and browsing a diff has no business moving what the window's
/// bottom edge says. The commit log is drawn only by the two panes that name
/// the worktree they are reading.
final recentCommitsProvider = FutureProvider.autoDispose<List<GitCommit>>((
  ref,
) async {
  final path = ref.watch(viewedCheckoutProvider);
  if (path == null) return const [];
  return ref.read(changesServiceProvider).log(path, limit: 8);
});

/// The worktrees of the selected repository.
///
/// Deliberately the *selected* checkout and not the viewed one: `git worktree
/// list` reports the same family from any member, and asking the browsed
/// worktree would fail exactly when it has just been removed — which is the
/// answer this list is needed for.
final repoWorktreesProvider = FutureProvider.autoDispose<List<GitWorktree>>((
  ref,
) async {
  final id = ref.watch(selectedRepositoryIdProvider);
  if (id == null) return const [];
  final repo = ref.read(repositoryDaoProvider).getById(id);
  if (repo == null) return const [];
  return ref.read(worktreeServiceProvider).list(repo.path);
});

/// Unified diff for the selected file in the selected repository.
final fileDiffProvider = FutureProvider.autoDispose<String>((ref) async {
  final file = ref.watch(selectedChangeFileProvider);
  if (file == null) return '';
  return ref.watch(fileDiffByPathProvider(file).future);
});

/// Unified diff for a specific [path] within the checkout being viewed — used
/// to render each changed file's diff inline (expandable) in the Changes view.
final fileDiffByPathProvider = FutureProvider.autoDispose
    .family<String, String>((ref, path) async {
      final checkout = ref.watch(viewedCheckoutProvider);
      if (checkout == null) return '';
      return ref.read(changesServiceProvider).diff(checkout, path: path);
    });
