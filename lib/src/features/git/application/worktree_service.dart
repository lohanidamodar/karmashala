import 'package:agent_cli/process.dart';
import '../../environments/application/environment_resolver.dart';
import '../../environments/data/execution_environment_dao.dart';
import '../data/git_service.dart';
import '../domain/git_worktree.dart';
import 'worktree_setup_service.dart';

/// Notified with a directory whose *existence* has just changed — a worktree
/// that has appeared or one that has been removed.
///
/// Quick Open's file index is the subscriber. Loop 62 wrote `invalidate` and
/// gave it no caller; this is it. A cached listing of a folder that has just
/// been created or destroyed is **wrong**, not merely old, and a fresh worktree
/// directory sits outside every root the OS watcher is watching — so nothing
/// else in the app would ever tell the index. A callback rather than the index
/// itself, because `git/` has no business importing `app/shell`.
typedef CheckoutMoved = void Function(EnvironmentPath directory);

/// High-level worktree lifecycle, resolving the correct runner for each
/// repository's environment.
///
/// This is where a session's per-session worktree choice (ADR 0004) is realized:
/// callers create a worktree for a session, list a repo's worktrees, or remove a
/// worktree. The worktree directory is derived environment-aware via
/// [worktreePathFor]; Git remains the source of truth.
class WorktreeService {
  WorktreeService({
    required this.runnerFactory,
    required this.environmentDao,
    this.onCheckoutMoved,
    this.setup,
  });

  final CommandRunnerFactory runnerFactory;
  final ExecutionEnvironmentDao environmentDao;

  /// See [CheckoutMoved]. Null in a test that is only asserting git arguments.
  final CheckoutMoved? onCheckoutMoved;

  /// What a repository wants done to a worktree the moment git makes one.
  ///
  /// Nullable for the same reason [onCheckoutMoved] is: a service composed to
  /// assert git arguments has no business needing a database, and a container
  /// with no terminal has nowhere visible to run a command. A null here is
  /// **no setup at all**, not a silent one.
  final WorktreeSetupService? setup;

  /// Where [repo]'s git runs, or the resolver's own refusal as a
  /// [GitException] — the words are its, so this cannot drift from the other
  /// launch paths.
  ExecutionEnvironment _environmentOf(EnvironmentPath repo) {
    final resolved = ExecutionEnvironmentResolver(
      environments: environmentDao,
      runners: runnerFactory,
    ).resolveFor(repo);
    final env = resolved.environment;
    if (env == null) throw GitException(resolved.reason);
    return env;
  }

  GitService _gitFor(EnvironmentPath repo) =>
      GitService(runnerFactory.forEnvironment(_environmentOf(repo)));

  /// Lists the worktrees of [repo].
  Future<List<GitWorktree>> list(EnvironmentPath repo) =>
      _gitFor(repo).listWorktrees(repo);

  /// Creates a worktree named [worktreeName] for [repo] on a new [branch].
  ///
  /// The location is computed as a sibling `.karmashala-worktrees/…` folder in
  /// the repository's environment. Returns the created worktree.
  ///
  /// **The setup hook is here and nowhere else.** All three callers reach this
  /// method — the session launcher, `SessionEngine.start` and the
  /// `worktree_create` MCP tool — so one hook covers every way a worktree comes
  /// into being, including a fan-out that makes four at once. And it is here
  /// rather than in each caller because the environment is already resolved at
  /// this point, which is what the setup needs to run in the repository's own
  /// environment rather than on whatever host the app happens to be.
  Future<GitWorktree> createForSession({
    required EnvironmentPath repo,
    required String worktreeName,
    required String branch,
    String? baseRef,
  }) async {
    final env = _environmentOf(repo);
    final git = GitService(runnerFactory.forEnvironment(env));
    final path = worktreePathFor(env.kind, repo, worktreeName);
    final worktree = await git.addWorktree(
      repo,
      worktreePath: path,
      branch: branch,
      baseRef: baseRef,
    );

    // **Awaited, and it cannot fail the create.** Awaited because the copy is
    // what makes the tree buildable — an agent launched into a worktree whose
    // `.dart_tool` is still arriving would race it, which is worse than not
    // copying at all. Swallowed because git has already made the directory:
    // throwing here would abort the session launch and leave an orphan
    // worktree, so a setup that went wrong is a recorded verdict instead. The
    // service does not throw; this is the belt for the case where something
    // under it does.
    try {
      await setup?.run(environment: env, repo: repo, worktree: path);
    } on Object {
      // Deliberately nothing: `WorktreeSetupService.run` records its own
      // failures in sentences, and a stack trace here would be about the app
      // rather than about the worktree.
    }

    // After the setup, not before: the copied files are part of what has just
    // appeared, and an index invalidated before they land would be re-warmed
    // on a directory that was still filling up.
    onCheckoutMoved?.call(path);
    return worktree;
  }

  /// Removes the worktree at [worktree] of [repo].
  Future<void> remove(
    EnvironmentPath repo,
    EnvironmentPath worktree, {
    bool force = false,
  }) async {
    await _gitFor(repo).removeWorktree(repo, worktree, force: force);
    // Only after git actually removed it: announcing a directory that is still
    // there would throw away a listing that is still correct.
    onCheckoutMoved?.call(worktree);
  }
}
