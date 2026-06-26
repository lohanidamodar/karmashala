import '../../../core/process/command_runner_factory.dart';
import '../../environments/data/execution_environment_dao.dart';
import '../../environments/domain/environment_path.dart';
import '../data/git_service.dart';
import '../domain/git_worktree.dart';

/// High-level worktree lifecycle, resolving the correct runner for each
/// repository's environment.
///
/// This is where a session's per-session worktree choice (ADR 0004) is realized:
/// callers create a worktree for a session, list a repo's worktrees, or remove a
/// worktree. The worktree directory is derived environment-aware via
/// [worktreePathFor]; Git remains the source of truth.
class WorktreeService {
  WorktreeService({required this.runnerFactory, required this.environmentDao});

  final CommandRunnerFactory runnerFactory;
  final ExecutionEnvironmentDao environmentDao;

  GitService _gitFor(EnvironmentPath repo) {
    final env = environmentDao.getById(repo.environmentId);
    if (env == null) {
      throw GitException('Unknown environment: ${repo.environmentId}');
    }
    return GitService(runnerFactory.forEnvironment(env));
  }

  /// Lists the worktrees of [repo].
  Future<List<GitWorktree>> list(EnvironmentPath repo) =>
      _gitFor(repo).listWorktrees(repo);

  /// Creates a worktree named [worktreeName] for [repo] on a new [branch].
  ///
  /// The location is computed as a sibling `.chitragupta-worktrees/…` folder in
  /// the repository's environment. Returns the created worktree.
  Future<GitWorktree> createForSession({
    required EnvironmentPath repo,
    required String worktreeName,
    required String branch,
    String? baseRef,
  }) {
    final env = environmentDao.getById(repo.environmentId);
    if (env == null) {
      throw GitException('Unknown environment: ${repo.environmentId}');
    }
    final git = GitService(runnerFactory.forEnvironment(env));
    final path = worktreePathFor(env.kind, repo, worktreeName);
    return git.addWorktree(
      repo,
      worktreePath: path,
      branch: branch,
      baseRef: baseRef,
    );
  }

  /// Removes the worktree at [worktree] of [repo].
  Future<void> remove(
    EnvironmentPath repo,
    EnvironmentPath worktree, {
    bool force = false,
  }) => _gitFor(repo).removeWorktree(repo, worktree, force: force);
}
