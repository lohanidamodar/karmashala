import 'package:agent_cli/process.dart';

import '../../git/domain/git_worktree.dart';
import 'checkout.dart';
import 'repository.dart';

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

  Map<String, Object?> toJson() => {
    'isWorktree': isWorktree,
    'branch': ?branch,
    'owner': ?ownerRepositoryId,
  };

  static CheckoutLabel fromJson(Map<String, Object?> json) => CheckoutLabel(
    isWorktree: json['isWorktree'] == true,
    branch: json['branch'] as String?,
    ownerRepositoryId: json['owner'] as String?,
  );

  @override
  bool operator ==(Object other) =>
      other is CheckoutLabel &&
      other.isWorktree == isWorktree &&
      other.branch == branch &&
      other.ownerRepositoryId == ownerRepositoryId;

  @override
  int get hashCode => Object.hash(isWorktree, branch, ownerRepositoryId);

  @override
  String toString() =>
      'CheckoutLabel(worktree: $isWorktree, branch: $branch, '
      'owner: $ownerRepositoryId)';
}

/// Worktree-or-not and branch for every one of [repositories], from `git
/// worktree list` ([list]) — **once per repository family**: rows [familyKey]
/// files under one key are asked once, all families at once, and a row with
/// no key (an SSH host) only when no earlier listing already named it. A
/// checkout whose git could not answer is **absent** from the map rather than
/// wrong in it.
Future<Map<String, CheckoutLabel>> readCheckoutLabels(
  List<Repository> repositories,
  Future<List<GitWorktree>> Function(EnvironmentPath checkout) list, {
  Future<String?> Function(EnvironmentPath checkout)? familyKey,
}) async {
  // Keyed by [Checkout]: git reports forward slashes where the table holds
  // backslashes, and both spell one directory.
  final byPath = <Checkout, String>{
    for (final repository in repositories)
      Checkout(repository.path): repository.id,
  };
  final family = <Checkout, ({String? branch, bool isMain, String? owner})>{};

  void record(List<GitWorktree>? listed) {
    if (listed == null || listed.isEmpty) return;
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

  Future<List<GitWorktree>?> listOrNull(EnvironmentPath path) async {
    try {
      return await list(path);
    } on Object {
      return null;
    }
  }

  final keys = familyKey == null
      ? [for (final _ in repositories) null]
      : await Future.wait([
          for (final repository in repositories)
            () async {
              try {
                return await familyKey(repository.path);
              } on Object {
                return null;
              }
            }(),
        ]);
  final representatives = <String, EnvironmentPath>{};
  final unkeyed = <Repository>[];
  for (var i = 0; i < repositories.length; i++) {
    final key = keys[i];
    if (key == null) {
      unkeyed.add(repositories[i]);
      continue;
    }
    representatives.putIfAbsent(key, () => repositories[i].path);
  }
  for (final listed in await Future.wait([
    for (final path in representatives.values) listOrNull(path),
  ])) {
    record(listed);
  }
  for (final repository in unkeyed) {
    if (family.containsKey(Checkout(repository.path))) continue;
    record(await listOrNull(repository.path));
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
