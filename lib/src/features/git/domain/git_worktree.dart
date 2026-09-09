import 'package:agent_cli/process.dart';

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

  /// The directory's own name — the only short thing a detached worktree can
  /// be listed under.
  String get name => lastPathSegment(path.path);

  /// What to call this worktree in a list: its branch, or its folder.
  String get label => branch ?? name;

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

/// The last segment of [path], whichever separator it was written with.
///
/// Split by hand rather than with `p.basename`: a Windows path is read on a
/// POSIX host in tests, and there `p.basename` returns the whole string.
String lastPathSegment(String path) {
  final segments = path
      .replaceAll(r'\', '/')
      .split('/')
      .where((segment) => segment.isNotEmpty);
  return segments.isEmpty ? path : segments.last;
}
