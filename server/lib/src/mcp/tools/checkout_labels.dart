import 'package:agent_cli/process.dart';
import 'package:karmashala_git/git.dart';
import 'package:karmashala_git/repositories.dart';

/// Whether a checkout is a linked worktree, the branch it has out, and which
/// recorded repository it is a worktree *of*.
class CheckoutLabel {
  const CheckoutLabel({
    required this.isWorktree,
    this.branch,
    this.ownerRepositoryId,
  });

  final bool isWorktree;

  /// Null when detached or unreported.
  final String? branch;

  /// The `repositories` row holding this family's **main** worktree. Only
  /// `git worktree list` knows it: a worktree is a *sibling* of its main
  /// checkout more often than a child, so containment cannot work it out.
  final String? ownerRepositoryId;
}

/// Worktree-or-not and branch for every one of [repositories], from `git
/// worktree list` ([list]) — once per family: a checkout an earlier listing
/// already named is not asked again. A checkout whose git could not answer is
/// **absent** from the map rather than wrong in it.
Future<Map<String, CheckoutLabel>> readCheckoutLabels(
  List<Repository> repositories,
  Future<List<GitWorktree>> Function(EnvironmentPath checkout) list,
) async {
  // Keyed by [Checkout]: git reports forward slashes where the table holds
  // backslashes, and both spell one directory.
  final byPath = <Checkout, String>{
    for (final repository in repositories)
      Checkout(repository.path): repository.id,
  };
  final family = <Checkout, ({String? branch, bool isMain, String? owner})>{};

  for (final repository in repositories) {
    if (family.containsKey(Checkout(repository.path))) continue;
    final List<GitWorktree> listed;
    try {
      listed = await list(repository.path);
    } on Object {
      continue;
    }
    if (listed.isEmpty) continue;
    // `git worktree list` prints the main worktree first, always.
    final owner = byPath[Checkout(listed.first.path)];
    for (var i = 0; i < listed.length; i++) {
      family.putIfAbsent(
        Checkout(listed[i].path),
        () => (
          branch: listed[i].branch,
          isMain: i == 0,
          owner: i == 0 ? null : owner,
        ),
      );
    }
  }

  return {
    for (final repository in repositories)
      if (family[Checkout(repository.path)] case final entry?)
        repository.id: CheckoutLabel(
          isWorktree: !entry.isMain,
          branch: entry.branch,
          ownerRepositoryId: entry.owner,
        ),
  };
}
