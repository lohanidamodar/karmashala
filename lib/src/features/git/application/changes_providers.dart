import 'package:riverpod/riverpod.dart';

import '../../../app/shell/quick_open/repo_file_index.dart';
import '../../../core/process/command_runner_providers.dart';
import '../../editor/application/code_editor_providers.dart';
import '../../environments/application/environment_providers.dart';
import '../../environments/application/environment_resolver.dart';
import 'package:agent_cli/process.dart';
import '../../explorer/application/checkout.dart';
import '../../projects/application/projects_controller.dart';
import '../../repositories/application/repository_providers.dart';
import '../../repositories/domain/repository.dart';
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

/// The selected repository itself, for the widgets that want the row rather
/// than the list it came out of.
///
/// Watch this, not `selectedProjectRepositoriesProvider`, unless you genuinely
/// need every repository. `Repository` has value equality and a `List` does
/// not, so a rebuilt list is never `==` to the last one and Riverpod's dedupe
/// cannot fire — every announcement reaches every watcher whether or not
/// anything moved. The list has to announce that freely, because the
/// repositories table has no notifier of its own and it stands in as the
/// change signal (see `selectedProjectRepositoriesProvider`); this derivation
/// is where that noise is absorbed.
///
/// It is not a micro-optimisation. `ShellStatusBar` and the side panel's
/// `_ChangesSurface` are siblings, and Flutter allows only a *descendant* of
/// the widget being built to be marked dirty — so one redundant announcement
/// arriving during the build phase threw `markNeedsBuild() called during
/// build`, taking the frame's layout with it.
final selectedRepositoryProvider = Provider<Repository?>((ref) {
  final id = ref.watch(selectedRepositoryIdProvider);
  if (id == null) return null;
  return ref
      .watch(selectedProjectRepositoriesProvider)
      .where((r) => r.id == id)
      .firstOrNull;
});

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
/// reading the `fatal:` — which is where the reported spin came from. See
/// `GitPresenceReader` for what a spawn costs and why the walk climbs.
///
/// Keyed by the checkout, not the repository row: the Repository pane asks
/// about the selected checkout and the Changes pane about the worktree being
/// read, and those diverge the moment somebody touches the picker.
final checkoutGitPresenceProvider = FutureProvider.autoDispose
    .family<GitPresence, EnvironmentPath>((ref, checkout) async {
      final env = ref
          .read(environmentResolverProvider)
          .resolveFor(checkout)
          .environment;
      // No environment row is not a statement about the folder; the git path
      // has its own `GitException` for that.
      if (env == null) return GitPresence.unknown;
      return GitPresenceReader(
        files: ref.watch(gitFilesProvider),
        hostPathOf: hostPathMapperFor(env),
      ).read(checkout.path);
    });

/// Throws [NotAGitRepository] when the filesystem has already said [checkout]
/// is not under version control, so nothing below spawns to be told the same.
/// The throw lands in each pane's `AsyncError` branch, where [gitTroubleOf]
/// makes it a sentence.
///
/// **Every caller reads its service before awaiting this** — the rule
/// `delivery_providers.dart` states at its own seams. This is the first `await`
/// these providers had, and a `ref.read` after one can throw on a disposed
/// `Ref` when the provider was invalidated in the gap, which is exactly what
/// moving the checkout picker does.
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
/// Riverpod 3's `defaultRetry` allows ten attempts backing off 200 ms → 6.4 s:
/// 38 seconds, and eleven `CreateProcessW` to be told `fatal:` eleven times.
/// That is the "stays loading for a long time" half of the report, and the
/// probe alone would not have fixed it — [NotAGitRepository] is an `Exception`
/// too, so the calm message would have taken the same 38 s to appear.
///
/// A real failure — a contended index lock — keeps the default policy, because
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

/// **Whether there is a merge to abort in the checkout being viewed.**
///
/// Derived from the listing the panel is already showing, and only where that
/// listing cannot answer: a conflicted row *is* an unfinished merge, so the
/// common case costs nothing at all. The second half is for the state the
/// listing genuinely cannot see — every conflict resolved and `git add`-ed,
/// nothing committed — where `.git/MERGE_HEAD` is still on disk and the button
/// is still the thing to press. One `stat`, no process, and no poll: this
/// recomputes exactly when [repositoryChangesProvider] does, because that is
/// what it watches.
///
/// **A `.git` that could not be read leaves the listing's answer standing**
/// rather than turning into a `false` — an unreadable share is not evidence
/// that no merge is in progress.
final mergeInProgressProvider = FutureProvider.autoDispose<bool>((ref) async {
  final listing = ref.watch(repositoryChangesProvider.future);
  final List<FileChange> changes;
  try {
    changes = await listing;
  } on Object {
    // A listing git could not produce says nothing about a merge, and the pane
    // beside this is already showing git's own words for it. Swallowed rather
    // than rethrown so this does not inherit the retry the listing owns — the
    // backoff timer would outlive the pane, which is what
    // [_retryOnlyRealFailures] exists to stop.
    return false;
  }
  // **A clean tree is not a merge**, and that is an answer rather than a
  // shortcut: a merge that stopped left its own work in the index, resolving a
  // conflict with `git add` leaves it staged, and neither state has an empty
  // listing. So the overwhelmingly common case reads nothing at all.
  if (changes.isEmpty) return false;
  if (changes.any((c) => c.type == FileChangeType.conflicted)) return true;
  final path = ref.read(viewedCheckoutProvider);
  if (path == null) return false;
  return await ref.read(changesServiceProvider).mergeInProgress(path) ?? false;
});

/// The current branch of the selected repository.
final currentBranchProvider = FutureProvider.autoDispose<String?>((ref) async {
  final id = ref.watch(selectedRepositoryIdProvider);
  if (id == null) return null;
  final repo = ref.read(repositoryDaoProvider).getById(id);
  if (repo == null) return null;
  final changes = ref.read(changesServiceProvider);
  // A folder with no git in it is not a *detached* checkout, which is what this
  // provider's null means and what both surfaces draw for one.
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
  // Likewise: null here is "a clone with no `origin`", not a folder that was
  // never cloned.
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
  // Empty here is "one working tree and no others", drawn as `none`. A folder
  // that is not a repository has neither.
  await _requireRepository(ref, repo.path);
  return worktrees.list(repo.path);
}, retry: _retryOnlyRealFailures);

/// **One verdict for the whole GIT section**, or null when it has facts —
/// including while it is still finding out (§19: a pane that has been told
/// nothing keeps its `…`).
///
/// Four rows each answering "not a git repository" in a 240px panel is the same
/// fact spelled four times. The probe decides it where it can, because that
/// reading is about the *folder* and not about one git subcommand.
///
/// Where the probe was unsure it comes off [repoWorktreesProvider], and that
/// choice is load-bearing: unlike [currentBranchProvider], it reports a git
/// that could not answer instead of folding every non-zero exit into the null
/// it uses for "detached" — a repository with no commits yet has no `HEAD`, so
/// no verdict can be recovered from that one.
final selectedCheckoutGitTroubleProvider = Provider.autoDispose<
  GitTroubleReport?
>((ref) {
  final checkout = ref.watch(selectedCheckoutPathProvider);
  if (checkout == null) return null;
  if (ref.watch(checkoutGitPresenceProvider(checkout)).asData?.value ==
      GitPresence.notARepository) {
    return const GitTroubleReport(GitTrouble.notARepository);
  }
  // `.error`, not an `AsyncError` pattern: a failure Riverpod is still retrying
  // is an `AsyncLoading` *carrying* its error, and this must not go quiet for
  // the backoff while the Changes pane already says what happened — `.when`
  // skips its loading branch on a refresh for the same reason.
  final error = ref.watch(repoWorktreesProvider).error;
  if (error == null) return null;
  return switch (gitTroubleOf(error)) {
    // git's own text is the useful part of a real failure, and nothing but
    // noise beside the two states this app words for itself.
    GitTrouble.failed => GitTroubleReport(GitTrouble.failed, detail: '$error'),
    final trouble => GitTroubleReport(trouble),
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
