import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/shell/quick_open/repo_file_index.dart';
import '../../../core/process/command_runner_providers.dart';
import '../../editor/application/code_editor_providers.dart';
import '../../environments/application/environment_providers.dart';
import '../../environments/domain/environment_path.dart';
import '../../explorer/application/checkout.dart';
import '../../repositories/application/repository_providers.dart';
import '../data/git_files.dart';
import '../data/git_presence_reader.dart';
import '../domain/file_change.dart';
import '../domain/git_commit.dart';
import '../domain/git_presence.dart';
import '../domain/git_worktree.dart';
import 'changes_service.dart';
import 'git_providers.dart';

/// The filesystem `ChangesService.originFacts` and `GitPresenceReader` read
/// `.git` through.
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

/// **Whether a checkout is under git, at the cost of no processes at all.**
///
/// The panes' first question, and it used to be asked by running `git` and
/// reading the `fatal:` that came back — which is where the reported spin came
/// from. `GitPresenceReader` reads the filesystem instead; see it for what a
/// spawn costs and for why the walk climbs to the root.
///
/// Keyed by the checkout rather than by the repository row, because the
/// Repository pane asks about the selected checkout and the Changes pane about
/// whichever worktree is being read, and those are the same directory only
/// until somebody touches the worktree picker.
final checkoutGitPresenceProvider = FutureProvider.autoDispose
    .family<GitPresence, EnvironmentPath>((ref, checkout) async {
      final env = ref
          .read(executionEnvironmentDaoProvider)
          .getById(checkout.environmentId);
      // No environment row is not a statement about the folder. The git path
      // has its own `GitException` for that and gets to make it.
      if (env == null) return GitPresence.unknown;
      return GitPresenceReader(
        files: ref.watch(gitFilesProvider),
        hostPathOf: hostPathMapperFor(env),
      ).read(checkout.path);
    });

/// Throws [NotAGitRepository] when the filesystem has **already** said
/// [checkout] is not under version control, so nothing below spawns a process
/// to be told the same thing.
///
/// It throws rather than returning an empty answer because each provider that
/// calls it already has a null or an empty list with a different meaning — "no
/// remote", "detached", "no other worktrees", "no changes" — and a folder with
/// no git in it is none of those. The throw lands in each pane's existing
/// `AsyncError` branch, where [gitTroubleOf] turns it into the calm sentence.
///
/// **Every caller reads its service before awaiting this**, which is the rule
/// `delivery_providers.dart` states at each of its own seams: this introduced
/// the first `await` those providers had, and a `ref.read` on the far side of
/// one can throw on a disposed `Ref` when the provider was invalidated in the
/// gap — which is exactly what moving the checkout picker does.
Future<void> _requireRepository(Ref ref, EnvironmentPath checkout) async {
  final presence = await ref.watch(
    checkoutGitPresenceProvider(checkout).future,
  );
  if (presence == GitPresence.notARepository) {
    throw NotAGitRepository(checkout);
  }
}

/// **Ask git again only where asking again could change the answer.**
///
/// Riverpod 3 retries a failed provider by itself: `defaultRetry` allows ten
/// attempts, backing off 200 ms, 400, 800 … capped at 6.4 s — **38 seconds**
/// of `AsyncLoading` in total, because a retrying element carries its error
/// *inside* a loading state and `.when` therefore draws the spinner. Before the
/// probe above existed it was also eleven `CreateProcessW` to be told `fatal:`
/// eleven times.
///
/// That is the other half of the report — "stays loading for a long time" — and
/// the filesystem probe alone would not have fixed it: [NotAGitRepository] is
/// an `Exception` too, so the calm message would have taken the same 38 seconds
/// to appear. A verdict does not become a different verdict by being asked
/// again, so both settled verdicts stop at the first answer. A real failure — a
/// contended index lock, a transient read — keeps the default policy, because
/// that one genuinely can come good on its own.
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

/// The current branch of the selected repository.
final currentBranchProvider = FutureProvider.autoDispose<String?>((ref) async {
  final id = ref.watch(selectedRepositoryIdProvider);
  if (id == null) return null;
  final repo = ref.read(repositoryDaoProvider).getById(id);
  if (repo == null) return null;
  final changes = ref.read(changesServiceProvider);
  // A folder with no git in it is not a **detached** checkout, which is what
  // this provider's null means and what the status bar and the Repository pane
  // both draw for one.
  await _requireRepository(ref, repo.path);
  return changes.currentBranch(repo.path);
}, retry: _retryOnlyRealFailures);

/// The `origin` remote URL of the selected repository.
final repoRemoteUrlProvider = FutureProvider.autoDispose<String?>((ref) async {
  final id = ref.watch(selectedRepositoryIdProvider);
  if (id == null) return null;
  final repo = ref.read(repositoryDaoProvider).getById(id);
  if (repo == null) return null;
  final changes = ref.read(changesServiceProvider);
  // Likewise: null here means "a clone with no `origin`", which is a different
  // thing from a folder that was never cloned.
  await _requireRepository(ref, repo.path);
  return changes.remoteUrl(repo.path);
}, retry: _retryOnlyRealFailures);

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
  final changes = ref.read(changesServiceProvider);
  await _requireRepository(ref, path);
  return changes.log(path, limit: 8);
}, retry: _retryOnlyRealFailures);

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
  final worktrees = ref.read(worktreeServiceProvider);
  // Empty here means "one working tree and no others", which every worktree
  // surface draws as `none`. A folder that is not a repository has neither.
  await _requireRepository(ref, repo.path);
  return worktrees.list(repo.path);
}, retry: _retryOnlyRealFailures);

/// Why the Repository pane has no git facts to show, or null when it has them
/// — including while it is still finding out.
///
/// **One verdict for the whole GIT section.** Branch, Remote, Worktrees and
/// Recent commits each answering "not a git repository" in a 240px panel is the
/// same fact spelled four times.
///
/// The probe decides it wherever it can, because that reading is about the
/// *folder* rather than about one git subcommand, and it is the reading the
/// report was filed about. Where the probe was unsure the verdict comes off
/// [repoWorktreesProvider], and that choice is load-bearing: it is the selected
/// checkout's — not the browsed worktree's — and, unlike [currentBranchProvider]
/// beside it, it **reports a git that could not answer** instead of returning
/// null. `git rev-parse --abbrev-ref HEAD` is allowed to fail for an ordinary
/// reason (a repository with no commits yet has no `HEAD` to resolve), so
/// `currentBranch` folds every non-zero exit into the null it uses for
/// "detached", and a verdict cannot be recovered from it. `git worktree list`
/// has no such ordinary failure.
///
/// Null while loading, so a pane that has not been told anything yet keeps its
/// `…` rather than asserting something it has not observed (§19).
final selectedCheckoutGitTroubleProvider = Provider.autoDispose<
  GitTroubleReport?
>((ref) {
  final checkout = ref.watch(selectedCheckoutPathProvider);
  if (checkout == null) return null;
  if (ref.watch(checkoutGitPresenceProvider(checkout)).asData?.value ==
      GitPresence.notARepository) {
    return const GitTroubleReport(GitTrouble.notARepository);
  }
  return switch (ref.watch(repoWorktreesProvider)) {
    AsyncError(:final error) => switch (gitTroubleOf(error)) {
      // git's own text is the useful part of a real failure, and nothing but
      // noise beside the two states this app words for itself.
      GitTrouble.failed => GitTroubleReport(
        GitTrouble.failed,
        detail: '$error',
      ),
      final trouble => GitTroubleReport(trouble),
    },
    _ => null,
  };
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
