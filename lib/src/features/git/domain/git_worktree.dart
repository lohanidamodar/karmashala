import '../../environments/domain/environment_path.dart';

/// A Git worktree as reported by `git worktree list`.
class GitWorktree {
  const GitWorktree({
    required this.path,
    this.branch,
    this.head,
    this.isBare = false,
  });

  /// Worktree location, bound to the repository's environment.
  final EnvironmentPath path;

  /// Checked-out branch (e.g. `feature/x`), or `null` when detached/bare.
  final String? branch;

  /// HEAD commit SHA, if reported.
  final String? head;

  /// Whether this is the bare repository entry.
  final bool isBare;

  @override
  bool operator ==(Object other) =>
      other is GitWorktree &&
      other.path == path &&
      other.branch == branch &&
      other.head == head &&
      other.isBare == isBare;

  @override
  int get hashCode => Object.hash(path, branch, head, isBare);

  @override
  String toString() => 'GitWorktree(${path.path}, branch: $branch)';
}
