import 'package:riverpod/riverpod.dart';

import 'package:agent_cli/process.dart';
import '../../../core/process/command_runner_providers.dart';
import '../../environments/application/environment_providers.dart';
import '../../environments/application/environment_resolver.dart';
import '../../environments/data/execution_environment_dao.dart';
import '../../git/application/changes_providers.dart';
import '../../repositories/application/repository_providers.dart';
import '../data/github_service.dart';
import 'package:karmashala_git/github.dart';

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
    final resolved = ExecutionEnvironmentResolver(
      environments: environmentDao,
      runners: runnerFactory,
    ).resolveFor(repo);
    final env = resolved.environment;
    if (env == null) throw GitHubException(resolved.reason);
    return GitHubService(runnerFactory.forEnvironment(env));
  }

  Future<GitHubRepo?> repository(EnvironmentPath repo) =>
      _ghFor(repo).getRepository(repo);

  Future<List<PullRequest>> pullRequests(EnvironmentPath repo) =>
      _ghFor(repo).listPullRequests(repo);

  Future<List<Issue>> issues(EnvironmentPath repo) =>
      _ghFor(repo).listIssues(repo);

  /// The pull request for [branch] and its checks, or `null` when the branch
  /// has none. Throws when `gh` could not answer at all — the caller decides
  /// what "could not tell" means for it.
  Future<PullRequestSnapshot?> pullRequestFor(
    EnvironmentPath repo, {
    required String branch,
  }) => _ghFor(repo).pullRequestFor(repo, branch: branch);

  /// The repository's merge settings and the pull request's open review
  /// conversations. One extra process, and only the session strip pays it —
  /// see `checkoutForgePolicyProvider`.
  Future<ForgePolicy> forgePolicyFor(
    EnvironmentPath repo, {
    required int number,
  }) => _ghFor(repo).forgePolicyFor(repo, number: number);

  /// The branch-protection rules on [branch]. One more process, paid only
  /// when a merge has already been read as `BLOCKED` — see
  /// `checkoutMergeProtectionProvider`.
  Future<BranchProtection> branchProtectionFor(
    EnvironmentPath repo, {
    required String branch,
  }) => _ghFor(repo).branchProtectionFor(repo, branch: branch);

  /// Takes pull request [number] out of draft. The app's own operation; see
  /// `DeliveryAction.markReady` for why it is not a prompt.
  Future<void> markPullRequestReady(
    EnvironmentPath repo, {
    required int number,
  }) => _ghFor(repo).markPullRequestReady(repo, number: number);

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

/// GitHub metadata for the selected repository (null if not a GitHub repo).
final githubRepositoryProvider = FutureProvider.autoDispose<GitHubRepo?>((
  ref,
) async {
  final id = ref.watch(selectedRepositoryIdProvider);
  if (id == null) return null;
  final repo = ref.read(repositoryDaoProvider).getById(id);
  if (repo == null) return null;
  return ref.read(gitHubReviewServiceProvider).repository(repo.path);
});

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
