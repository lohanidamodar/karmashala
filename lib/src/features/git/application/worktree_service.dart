import 'package:agent_cli/process.dart';
import '../../environments/application/environment_resolver.dart';
import '../../environments/data/execution_environment_dao.dart';
import 'package:karmashala_git/git.dart';
import 'worktree_setup_service.dart';

/// Notified with a directory whose *existence* has just changed. A fresh
/// worktree sits outside every root the OS watcher watches, so nothing else
/// would ever tell Quick Open's index its cached listing is now wrong.
typedef CheckoutMoved = void Function(EnvironmentPath directory);

/// High-level worktree lifecycle, resolving the correct runner for each
/// repository's environment. Where a session's per-session worktree choice
/// (ADR 0004) is realised; git remains the source of truth.
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

  /// What a repository wants done to a worktree the moment git makes one. Null
  /// is no setup at all, never a silent one.
  final WorktreeSetupService? setup;

  /// Where [repo]'s git runs, or the resolver's own refusal as a
  /// [GitException], in its words so this cannot drift from the launch paths.
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

  /// Creates a worktree named [worktreeName] for [repo] on a new [branch], as a
  /// sibling `.karmashala-worktrees/…` folder in the repository's environment.
  ///
  /// The setup hook is here and nowhere else: all three callers reach this
  /// method, and the environment the setup must run in is already resolved.
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

    // Awaited, because an agent launched into a worktree whose `.dart_tool` is
    // still arriving would race it. Swallowed, because git has already made the
    // directory and throwing would leave an orphan worktree.
    try {
      await setup?.run(environment: env, repo: repo, worktree: path);
    } on Object {
      // Deliberately nothing: the service records its own failures in
      // sentences.
    }

    // After the setup: an index invalidated before the copies land would be
    // re-warmed on a directory that was still filling up.
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
    // Only after git actually removed it, or a still-correct listing would be
    // thrown away.
    onCheckoutMoved?.call(worktree);
  }
}
