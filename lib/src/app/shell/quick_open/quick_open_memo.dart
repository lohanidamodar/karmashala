import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/git/application/changes_providers.dart';
import '../../../features/git/domain/file_change.dart';
import '../../../features/github/application/github_providers.dart';
import '../../../features/github/domain/issue.dart';
import '../../../features/github/domain/pull_request.dart';

/// What quick open remembers about a repository from surfaces that already
/// loaded it.
class RepoMemo {
  const RepoMemo({
    this.branches = const [],
    this.pullRequests = const [],
    this.issues = const [],
    this.changedFiles = const [],
  });

  /// Branch names we have seen: the checked-out branch and every worktree's.
  final List<String> branches;
  final List<PullRequest> pullRequests;
  final List<Issue> issues;
  final List<FileChange> changedFiles;

  RepoMemo copyWith({
    List<String>? branches,
    List<PullRequest>? pullRequests,
    List<Issue>? issues,
    List<FileChange>? changedFiles,
  }) => RepoMemo(
    branches: branches ?? this.branches,
    pullRequests: pullRequests ?? this.pullRequests,
    issues: issues ?? this.issues,
    changedFiles: changedFiles ?? this.changedFiles,
  );
}

/// Everything quick open knows about repositories it did not load itself.
///
/// **Quick open never fetches.** Branches, pull requests, issues and the change
/// set all come from `gh` or `git` through providers that belong to other
/// features, and a search box that shells out on every keystroke — or even on
/// every open — is a search box that stalls and surprises. So this is a memo:
/// whatever those surfaces have already materialised is harvested when quick
/// open opens, kept after they are disposed, and searched from memory.
///
/// The cost is honest and bounded: a pull request is findable once the GitHub
/// surface has shown it, and it refreshes in place the next time that surface
/// runs. The alternative — spawning `gh` from a text field — is worse.
class QuickOpenMemoController extends Notifier<Map<String, RepoMemo>> {
  @override
  Map<String, RepoMemo> build() => const {};

  RepoMemo forRepository(String? repositoryId) => repositoryId == null
      ? const RepoMemo()
      : (state[repositoryId] ?? const RepoMemo());

  void remember(String repositoryId, RepoMemo Function(RepoMemo) update) {
    final next = update(state[repositoryId] ?? const RepoMemo());
    state = {...state, repositoryId: next};
  }
}

final quickOpenMemoProvider =
    NotifierProvider<QuickOpenMemoController, Map<String, RepoMemo>>(
      QuickOpenMemoController.new,
    );

/// Copies whatever the git and GitHub surfaces currently hold for the selected
/// repository into the memo.
///
/// [ProviderContainer.exists] is the whole trick: it answers "has anyone loaded
/// this?" without becoming a listener, so a provider nobody is using stays
/// unbuilt and no command runs.
void harvestLoadedRepoData(ProviderContainer container) {
  final repositoryId = container.read(selectedRepositoryIdProvider);
  if (repositoryId == null) return;

  T? loaded<T>(FutureProvider<T> provider) {
    if (!container.exists(provider)) return null;
    return container.read(provider).asData?.value;
  }

  final branches = <String>[];
  final current = loaded(currentBranchProvider);
  if (current != null && current.isNotEmpty) branches.add(current);
  for (final worktree in loaded(repoWorktreesProvider) ?? const []) {
    final branch = worktree.branch;
    if (branch != null && branch.isNotEmpty && !branches.contains(branch)) {
      branches.add(branch);
    }
  }

  final pullRequests = loaded(githubPullRequestsProvider);
  final issues = loaded(githubIssuesProvider);
  final changes = loaded(repositoryChangesProvider);

  if (branches.isEmpty &&
      pullRequests == null &&
      issues == null &&
      changes == null) {
    return;
  }

  container
      .read(quickOpenMemoProvider.notifier)
      .remember(
        repositoryId,
        (memo) => memo.copyWith(
          branches: branches.isEmpty ? null : branches,
          pullRequests: pullRequests,
          issues: issues,
          changedFiles: changes,
        ),
      );
}
