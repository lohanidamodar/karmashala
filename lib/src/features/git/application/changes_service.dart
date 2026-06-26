import '../../../core/process/command_runner_factory.dart';
import '../../environments/data/execution_environment_dao.dart';
import '../../environments/domain/environment_path.dart';
import '../data/git_service.dart';
import '../domain/file_change.dart';
import '../domain/git_commit.dart';

/// High-level access to a repository's working-tree changes and diffs, resolving
/// the correct runner for the repository's environment. Read-only: Git is the
/// source of truth and there is no editor (ADR 0004).
class ChangesService {
  ChangesService({required this.runnerFactory, required this.environmentDao});

  final CommandRunnerFactory runnerFactory;
  final ExecutionEnvironmentDao environmentDao;

  GitService _gitFor(EnvironmentPath repo) {
    final env = environmentDao.getById(repo.environmentId);
    if (env == null) {
      throw GitException('Unknown environment: ${repo.environmentId}');
    }
    return GitService(runnerFactory.forEnvironment(env));
  }

  /// Changed files in [repo].
  Future<List<FileChange>> changes(EnvironmentPath repo) =>
      _gitFor(repo).status(repo);

  /// Unified diff for [repo], optionally limited to [path] / staged changes.
  Future<String> diff(
    EnvironmentPath repo, {
    String? path,
    bool staged = false,
  }) => _gitFor(repo).diff(repo, path: path, staged: staged);

  /// Recent commits for [repo].
  Future<List<GitCommit>> log(EnvironmentPath repo, {int limit = 20}) =>
      _gitFor(repo).log(repo, limit: limit);

  /// Stages all changes and commits them with [message].
  Future<void> commitAll(EnvironmentPath repo, String message) async {
    final git = _gitFor(repo);
    await git.stageAll(repo);
    await git.commit(repo, message);
  }

  /// Pushes the current branch of [repo].
  Future<void> push(EnvironmentPath repo) => _gitFor(repo).push(repo);
}
