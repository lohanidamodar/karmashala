/// How a file changed in the working tree, as reported by `git status`.
enum FileChangeType {
  added,
  modified,
  deleted,
  renamed,
  copied,
  untracked,
  unknown,
}

/// A single changed path in a repository's working tree.
class FileChange {
  const FileChange({
    required this.path,
    required this.type,
    required this.staged,
    required this.unstaged,
    this.originalPath,
  });

  /// Path relative to the repository root (the new path for renames).
  final String path;

  /// For renames/copies, the original path; otherwise `null`.
  final String? originalPath;

  final FileChangeType type;

  /// Whether there are staged (index) changes for this path.
  final bool staged;

  /// Whether there are unstaged (working-tree) changes for this path.
  final bool unstaged;

  @override
  bool operator ==(Object other) =>
      other is FileChange &&
      other.path == path &&
      other.originalPath == originalPath &&
      other.type == type &&
      other.staged == staged &&
      other.unstaged == unstaged;

  @override
  int get hashCode => Object.hash(path, originalPath, type, staged, unstaged);

  @override
  String toString() => 'FileChange($path, $type, staged:$staged)';
}
