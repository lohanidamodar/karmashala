import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/process/command_runner_factory.dart';
import '../../../core/process/command_runner_providers.dart';
import '../../environments/application/environment_providers.dart';
import '../../environments/data/execution_environment_dao.dart';
import '../../environments/domain/environment_path.dart';
import '../../git/application/changes_providers.dart';
import '../../repositories/application/repository_providers.dart';
import '../data/github_service.dart';
import '../domain/issue.dart';
import '../domain/pull_request.dart';

/// Resolves the right [GitHubService] (and runner) for a repository's
/// environment and exposes PR/issue queries.
class GitHubReviewService {
  GitHubReviewService({
    required this.runnerFactory,
    required this.environmentDao,
  });

  final CommandRunnerFactory runnerFactory;
  final ExecutionEnvironmentDao environmentDao;

  GitHubService _ghFor(EnvironmentPath repo) {
    final env = environmentDao.getById(repo.environmentId);
    if (env == null) {
      throw GitHubException('Unknown environment: ${repo.environmentId}');
    }
    return GitHubService(runnerFactory.forEnvironment(env));
  }

  Future<List<PullRequest>> pullRequests(EnvironmentPath repo) =>
      _ghFor(repo).listPullRequests(repo);

  Future<List<Issue>> issues(EnvironmentPath repo) =>
      _ghFor(repo).listIssues(repo);

  Future<String> createPullRequest(
    EnvironmentPath repo, {
    required String title,
    String body = '',
  }) => _ghFor(repo).createPullRequest(repo, title: title, body: body);
}

final gitHubReviewServiceProvider = Provider<GitHubReviewService>(
  (ref) => GitHubReviewService(
    runnerFactory: ref.watch(commandRunnerFactoryProvider),
    environmentDao: ref.watch(executionEnvironmentDaoProvider),
  ),
);

/// Which review tab is active for the selected repository (0 = changes,
/// 1 = GitHub).
class RepoReviewTabController extends Notifier<int> {
  @override
  int build() => 0;
  void select(int index) => state = index;
}

final repoReviewTabProvider = NotifierProvider<RepoReviewTabController, int>(
  RepoReviewTabController.new,
);

/// Open pull requests for the selected repository.
final githubPullRequestsProvider =
    FutureProvider.autoDispose<List<PullRequest>>((ref) async {
      final id = ref.watch(selectedRepositoryIdProvider);
      if (id == null) return const [];
      final repo = ref.read(repositoryDaoProvider).getById(id);
      if (repo == null) return const [];
      return ref.read(gitHubReviewServiceProvider).pullRequests(repo.path);
    });

/// Open issues for the selected repository.
final githubIssuesProvider = FutureProvider.autoDispose<List<Issue>>((
  ref,
) async {
  final id = ref.watch(selectedRepositoryIdProvider);
  if (id == null) return const [];
  final repo = ref.read(repositoryDaoProvider).getById(id);
  if (repo == null) return const [];
  return ref.read(gitHubReviewServiceProvider).issues(repo.path);
});
