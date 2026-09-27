import 'package:agent_cli/process.dart';
import 'package:karmashala_git/git.dart';
import 'package:karmashala_git/worktrees.dart';
import 'package:riverpod/riverpod.dart';

import '../data/git_data.dart';
import '../data/worktree_setup_data.dart';
import 'setup_run_pane.dart';

/// Worktrees, made and removed by the server (slice 3b) — its setup and
/// teardown run there too, as sessions it hosts. The same verbs the app's
/// own worktree service had, so a surface only says what it wants.
class WorktreesClient {
  WorktreesClient(
    this._git,
    this._creations, {
    this.runningSetupPane,
    this.showSetup,
  });

  final GitData _git;
  final WorktreeCreations _creations;

  /// Where a new worktree's setup command runs, and how its pane is shown:
  /// the command is the server's, and a person still watches it run.
  final String? Function(EnvironmentPath worktree)? runningSetupPane;
  final void Function(String paneId)? showSetup;

  /// The worktrees of [repo], the main one first.
  Future<List<GitWorktree>> list(EnvironmentPath repo) => _git.worktreesOf(repo);

  /// Makes a worktree in stages, told on [tracker] as they move, and
  /// published to [worktreeCreationsProvider] while it runs. With
  /// [launchesAgent] the agent stage is the caller's to settle on the tracker.
  Future<WorktreeCreated> create({
    required EnvironmentPath repo,
    required String worktreeName,
    required String branch,
    String? baseRef,
    bool launchesAgent = false,
    WorktreeCreationTracker? tracker,
  }) async {
    final created = await _git.createWorktree(
      repo: repo,
      worktreeName: worktreeName,
      branch: branch,
      baseRef: baseRef,
      launchesAgent: launchesAgent,
      tracker: tracker,
      creations: _creations,
    );
    // Its verdict was told before the answer, so the pane is known by now.
    final pane = runningSetupPane?.call(created.worktree.path);
    if (pane != null) showSetup?.call(pane);
    return created;
  }

  /// [create] with no agent of its own.
  Future<GitWorktree> createForSession({
    required EnvironmentPath repo,
    required String worktreeName,
    required String branch,
    String? baseRef,
    WorktreeCreationTracker? tracker,
  }) async => (await create(
    repo: repo,
    worktreeName: worktreeName,
    branch: branch,
    baseRef: baseRef,
    tracker: tracker,
  )).worktree;

  /// Removes [worktree] of [repo], its teardown first.
  Future<WorktreeTeardown?> remove(
    EnvironmentPath repo,
    EnvironmentPath worktree, {
    bool force = false,
  }) async {
    final said = await _git.removeWorktree(repo, worktree, force: force);
    return said == null ? null : WorktreeTeardown(said);
  }
}

final worktreeServiceProvider = Provider<WorktreesClient>(
  (ref) => WorktreesClient(
    ref.watch(gitDataProvider),
    ref.watch(worktreeCreationsProvider),
    runningSetupPane: (worktree) =>
        ref.read(worktreeSetupDataProvider).runningSetupPane(worktree),
    showSetup: (paneId) => showSetupRun(ref, paneId),
  ),
);

/// The worktree creations in flight, for a surface that did not start one.
final worktreeCreationsProvider = Provider<WorktreeCreations>(
  (ref) => WorktreeCreations(),
);
