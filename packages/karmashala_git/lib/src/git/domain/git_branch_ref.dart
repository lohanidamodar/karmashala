import 'package:agent_cli/process.dart';

/// One branch of a repository as `git for-each-ref` lists it: a local branch
/// (`refs/heads/`) or a remote-tracking one (`refs/remotes/`). What a person
/// picks a worktree's base, or the branch a worktree checks out, from.
class GitBranchRef {
  const GitBranchRef({
    required this.name,
    this.remote,
    this.isCurrent = false,
    this.upstream,
    this.worktree,
  });

  /// The short name git prints: `main`, `feature/x`, `origin/main`.
  final String name;

  /// The remote a remote-tracking branch belongs to (`origin`); null for a
  /// local branch.
  final String? remote;

  /// Whether this is the branch checked out in the checkout that was asked.
  final bool isCurrent;

  /// A local branch's upstream (`origin/main`), when it has one.
  final String? upstream;

  /// Where a local branch is checked out, in this checkout or another of its
  /// worktrees. Git lets a branch be checked out in only one place, so a
  /// branch with a worktree can only be joined there, never checked out anew.
  final EnvironmentPath? worktree;

  bool get isRemote => remote != null;

  /// The name without its remote: `feature/x` for `origin/feature/x` — the
  /// local branch a checkout of a remote-tracking one creates.
  String get localName =>
      remote == null ? name : name.substring(remote!.length + 1);

  GitBranchRef withWorktree(EnvironmentPath? worktree) => GitBranchRef(
    name: name,
    remote: remote,
    isCurrent: isCurrent,
    upstream: upstream,
    worktree: worktree,
  );

  @override
  bool operator ==(Object other) =>
      other is GitBranchRef &&
      other.name == name &&
      other.remote == remote &&
      other.isCurrent == isCurrent &&
      other.upstream == upstream &&
      other.worktree == worktree;

  @override
  int get hashCode => Object.hash(name, remote, isCurrent, upstream, worktree);

  @override
  String toString() => 'GitBranchRef($name${isCurrent ? ', current' : ''})';
}
