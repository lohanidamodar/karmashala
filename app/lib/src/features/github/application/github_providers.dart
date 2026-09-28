import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show GitHubOverview;
import 'package:karmashala_git/github.dart';
import 'package:riverpod/riverpod.dart';

import '../../git/application/changes_providers.dart';
import '../../git/application/remote_links.dart';
import '../../git/data/git_data.dart';
import '../../workspaces/data/workspace_data.dart';

/// Whether the selected checkout has a GitHub side to ask about, read off its
/// remote before `gh` is run at all.
enum GitHubReachKind {
  /// The remote is still being read, or could not be (git's trouble is shown
  /// where git's details are).
  unknown,

  /// No remote: the checkout is on this machine alone.
  noRemote,

  /// A remote on another forge (GitLab, Bitbucket, a self-hosted git), or one
  /// that is not a web address at all — [GitHubReach.host] null then.
  otherHost,

  /// A GitHub remote: `gh` is asked.
  gitHub,
}

typedef GitHubReach = ({GitHubReachKind kind, String? host});

/// A host is GitHub's when it is `github.com` or one of its enterprise
/// servers, which `gh` answers for as well once signed in to them.
bool isGitHubHost(String host) => host.contains('github');

/// Where [remote] (a checkout's `origin`, null for none) leaves GitHub.
GitHubReach gitHubReachOf(String? remote) {
  if (remote == null || remote.trim().isEmpty) {
    return (kind: GitHubReachKind.noRemote, host: null);
  }
  final host = remoteHostOf(remote);
  return host != null && isGitHubHost(host)
      ? (kind: GitHubReachKind.gitHub, host: host)
      : (kind: GitHubReachKind.otherHost, host: host);
}

final githubReachProvider = Provider.autoDispose<GitHubReach>(
  (ref) => switch (ref.watch(repoRemoteUrlProvider)) {
    AsyncData(:final value) => gitHubReachOf(value),
    _ => (kind: GitHubReachKind.unknown, host: null),
  },
);

/// The selected repository's page on GitHub — its metadata, open pull
/// requests and open issues — read through `gh` at the server. Only asked
/// for a checkout with a GitHub remote; any other answers empty.
final githubOverviewProvider = FutureProvider.autoDispose<GitHubOverview>((
  ref,
) async {
  // Waits for the remote rather than reading [githubReachProvider]: that says
  // `unknown` while the remote is read, and an overview answered then would
  // stay empty after it arrived. A remote git could not read is git's trouble,
  // said in the Git section; nothing is asked of `gh` for it.
  // Everything watched before the wait: a ref is not to be used after an
  // await that a rebuild may have outlived.
  final id = ref.watch(selectedRepositoryIdProvider);
  final remoteRead = ref.watch(repoRemoteUrlProvider.future);
  final git = ref.read(gitDataProvider);
  final repo = id == null
      ? null
      : ref.read(workspaceDataProvider).repository(id);
  if (repo == null) return const GitHubOverview();
  final String? remote;
  try {
    remote = await remoteRead;
  } on Object {
    return const GitHubOverview();
  }
  if (gitHubReachOf(remote).kind != GitHubReachKind.gitHub) {
    return const GitHubOverview();
  }
  return git.gitHubOverview(repo.path);
});

/// A part the server could not read is its answer until the user refreshes:
/// asking again at once gets the same `gh` refusal, and the default policy
/// spends 38 s showing a spinner over it.
Duration? _theServersAnswer(int count, Object error) => null;

/// GitHub metadata for the selected repository (null if not a GitHub repo).
/// Fails alone, with the server's reason, when it could not be read.
final githubRepositoryProvider = FutureProvider.autoDispose<GitHubRepo?>((
  ref,
) async {
  final overview = await ref.watch(githubOverviewProvider.future);
  if (overview.repositoryFailure case final failure?) {
    throw GitHubException(failure);
  }
  return overview.repository;
}, retry: _theServersAnswer);

/// Open pull requests for the selected repository.
final githubPullRequestsProvider =
    FutureProvider.autoDispose<List<PullRequest>>((ref) async {
      final overview = await ref.watch(githubOverviewProvider.future);
      if (overview.pullRequestsFailure case final failure?) {
        throw GitHubException(failure);
      }
      return overview.pullRequests;
    }, retry: _theServersAnswer);

/// Open issues for the selected repository.
final githubIssuesProvider = FutureProvider.autoDispose<List<Issue>>((
  ref,
) async {
  final overview = await ref.watch(githubOverviewProvider.future);
  if (overview.issuesFailure case final failure?) {
    throw GitHubException(failure);
  }
  return overview.issues;
}, retry: _theServersAnswer);
