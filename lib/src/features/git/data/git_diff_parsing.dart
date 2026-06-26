import '../domain/diff_line.dart';
import '../domain/file_change.dart';
import '../domain/git_commit.dart';

/// Parses `git status --porcelain=v1` output into [FileChange]s.
///
/// Each line is `XY <path>` where `X` is the index (staged) status and `Y` the
/// work-tree (unstaged) status. `??` marks untracked; `R`/`C` lines carry
/// `old -> new`. Pure and testable.
List<FileChange> parseGitStatus(String porcelain) {
  final changes = <FileChange>[];
  for (final raw in porcelain.split(RegExp(r'[\r\n]'))) {
    if (raw.length < 4) continue;
    final x = raw[0];
    final y = raw[1];
    final rest = raw.substring(3);

    String? originalPath;
    var path = rest;
    if (rest.contains(' -> ')) {
      final parts = rest.split(' -> ');
      originalPath = parts.first;
      path = parts.last;
    }

    final untracked = x == '?' && y == '?';
    final staged = !untracked && x != ' ';
    final unstaged = untracked || y != ' ';
    final code = untracked ? '?' : (x != ' ' ? x : y);

    changes.add(
      FileChange(
        path: path,
        originalPath: originalPath,
        type: _typeOf(code),
        staged: staged,
        unstaged: unstaged,
      ),
    );
  }
  return changes;
}

FileChangeType _typeOf(String code) => switch (code) {
  'A' => FileChangeType.added,
  'M' => FileChangeType.modified,
  'D' => FileChangeType.deleted,
  'R' => FileChangeType.renamed,
  'C' => FileChangeType.copied,
  '?' => FileChangeType.untracked,
  _ => FileChangeType.unknown,
};

/// Parses `git log --pretty=format:%H%x1f%an%x1f%s` output (unit-separated
/// fields, one commit per line) into [GitCommit]s.
List<GitCommit> parseGitLog(String output) {
  final unitSeparator = String.fromCharCode(0x1f); // %x1f in the format string
  final commits = <GitCommit>[];
  for (final line in output.split(RegExp(r'[\r\n]+'))) {
    if (line.isEmpty) continue;
    final parts = line.split(unitSeparator);
    if (parts.length < 3) continue;
    commits.add(GitCommit(sha: parts[0], author: parts[1], subject: parts[2]));
  }
  return commits;
}

/// Parses unified diff text into classified [DiffLine]s for display.
List<DiffLine> parseUnifiedDiff(String diff) {
  final lines = <DiffLine>[];
  for (final line in diff.split('\n')) {
    final DiffLineKind kind;
    if (line.startsWith('@@')) {
      kind = DiffLineKind.hunk;
    } else if (line.startsWith('+++') ||
        line.startsWith('---') ||
        line.startsWith('diff ') ||
        line.startsWith('index ') ||
        line.startsWith('new file') ||
        line.startsWith('deleted file') ||
        line.startsWith('rename ') ||
        line.startsWith('similarity ')) {
      kind = DiffLineKind.meta;
    } else if (line.startsWith('+')) {
      kind = DiffLineKind.added;
    } else if (line.startsWith('-')) {
      kind = DiffLineKind.removed;
    } else {
      kind = DiffLineKind.context;
    }
    lines.add(DiffLine(kind, line));
  }
  // Drop a single trailing empty context line from the final newline.
  if (lines.isNotEmpty &&
      lines.last.kind == DiffLineKind.context &&
      lines.last.text.isEmpty) {
    lines.removeLast();
  }
  return lines;
}
