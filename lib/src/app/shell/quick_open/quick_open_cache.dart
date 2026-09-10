import 'package:riverpod/riverpod.dart';

import '../../../features/git/application/changes_providers.dart';
import '../../../features/github/application/github_providers.dart';
import 'package:karmashala_git/github.dart';

/// What quick open knows about a repository from data somebody else already
/// fetched.
class LoadedRepoFacts {
  const LoadedRepoFacts({
    this.pullRequests = const [],
    this.issues = const [],
    this.branches = const [],
  });

  final List<PullRequest> pullRequests;
  final List<Issue> issues;

  /// Branch names, most useful first (the checked-out one, then worktrees).
  final List<String> branches;

  bool get isEmpty =>
      pullRequests.isEmpty && issues.isEmpty && branches.isEmpty;
}

/// Remembers the GitHub and branch data already loaded, so quick open can search
/// it without a call of its own; a repository never opened has no PRs to find.
class QuickOpenCache extends Notifier<Map<String, LoadedRepoFacts>> {
  @override
  Map<String, LoadedRepoFacts> build() => const {};

  LoadedRepoFacts factsFor(String? repositoryId) => repositoryId == null
      ? const LoadedRepoFacts()
      : (state[repositoryId] ?? const LoadedRepoFacts());

  /// Copies whatever the live providers hold for [repositoryId]. `exists` is the
  /// whole point: reading a provider that is not alive would *create* it.
  void harvest(ProviderContainer container, String? repositoryId) {
    if (repositoryId == null) return;
    final previous = factsFor(repositoryId);

    final pullRequests = container.exists(githubPullRequestsProvider)
        ? container.read(githubPullRequestsProvider).asData?.value ?? const []
        : const <PullRequest>[];
    final issues = container.exists(githubIssuesProvider)
        ? container.read(githubIssuesProvider).asData?.value ?? const []
        : const <Issue>[];

    final branches = <String>[];
    if (container.exists(currentBranchProvider)) {
      final current = container.read(currentBranchProvider).asData?.value;
      if (current != null) branches.add(current);
    }
    if (container.exists(repoWorktreesProvider)) {
      final worktrees =
          container.read(repoWorktreesProvider).asData?.value ?? const [];
      for (final worktree in worktrees) {
        final branch = worktree.branch;
        if (branch != null && !branches.contains(branch)) branches.add(branch);
      }
    }

    final next = LoadedRepoFacts(
      // Nothing loaded this time must not erase what was loaded last time.
      pullRequests: pullRequests.isEmpty ? previous.pullRequests : pullRequests,
      issues: issues.isEmpty ? previous.issues : issues,
      branches: branches.isEmpty ? previous.branches : branches,
    );
    if (next.isEmpty) return;
    state = {...state, repositoryId: next};
  }
}

final quickOpenCacheProvider =
    NotifierProvider<QuickOpenCache, Map<String, LoadedRepoFacts>>(
      QuickOpenCache.new,
    );
