import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show GitHubOverview;
import 'package:karmashala_git/github.dart';
import 'package:riverpod/riverpod.dart';

import '../../git/application/changes_providers.dart';
import '../../git/data/git_data.dart';
import '../../workspaces/data/workspace_data.dart';

/// The selected repository's page on GitHub — its metadata, open pull
/// requests and open issues — read through `gh` at the server.
final githubOverviewProvider = FutureProvider.autoDispose<GitHubOverview>((
  ref,
) async {
  final id = ref.watch(selectedRepositoryIdProvider);
  if (id == null) return const GitHubOverview();
  final repo = ref.read(workspaceDataProvider).repository(id);
  if (repo == null) return const GitHubOverview();
  return ref.read(gitDataProvider).gitHubOverview(repo.path);
});

/// GitHub metadata for the selected repository (null if not a GitHub repo).
final githubRepositoryProvider = FutureProvider.autoDispose<GitHubRepo?>(
  (ref) async => (await ref.watch(githubOverviewProvider.future)).repository,
);

/// Open pull requests for the selected repository.
final githubPullRequestsProvider =
    FutureProvider.autoDispose<List<PullRequest>>(
      (ref) async =>
          (await ref.watch(githubOverviewProvider.future)).pullRequests,
    );

/// Open issues for the selected repository.
final githubIssuesProvider = FutureProvider.autoDispose<List<Issue>>(
  (ref) async => (await ref.watch(githubOverviewProvider.future)).issues,
);
