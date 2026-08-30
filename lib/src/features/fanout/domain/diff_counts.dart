import 'dart:convert';

/// Lines added and removed in a unified diff.
///
/// Counted here rather than asked of git: `--numstat` would mean a new method on
/// `GitService`, and the fan-out already has the diff text in hand for the
/// side-by-side view. Pure, so it is testable without a repository.
///
/// The *file* count deliberately does not live here — `git status` knows it
/// without double-counting a file that is both staged and modified, and it sees
/// untracked files that no `git diff` will ever mention.
class DiffLineCounts {
  const DiffLineCounts({required this.insertions, required this.deletions});

  static const none = DiffLineCounts(insertions: 0, deletions: 0);

  final int insertions;
  final int deletions;

  DiffLineCounts operator +(DiffLineCounts other) => DiffLineCounts(
    insertions: insertions + other.insertions,
    deletions: deletions + other.deletions,
  );

  @override
  bool operator ==(Object other) =>
      other is DiffLineCounts &&
      other.insertions == insertions &&
      other.deletions == deletions;

  @override
  int get hashCode => Object.hash(insertions, deletions);

  @override
  String toString() => 'DiffLineCounts(+$insertions, -$deletions)';
}

/// Counts changed lines in a unified diff.
///
/// Only lines inside a hunk count: `+++ b/file` and `--- a/file` are headers,
/// `\ No newline at end of file` is neither, and miscounting those is the whole
/// difficulty here.
DiffLineCounts parseDiffLineCounts(String diff) {
  if (diff.trim().isEmpty) return DiffLineCounts.none;
  var insertions = 0;
  var deletions = 0;
  var inHunk = false;

  for (final line in const LineSplitter().convert(diff)) {
    if (line.startsWith('diff --git ')) {
      inHunk = false;
      continue;
    }
    if (line.startsWith('@@')) {
      inHunk = true;
      continue;
    }
    if (!inHunk) continue;
    if (line.startsWith('+++') || line.startsWith('---')) continue;
    if (line.startsWith('+')) {
      insertions++;
    } else if (line.startsWith('-')) {
      deletions++;
    }
  }

  return DiffLineCounts(insertions: insertions, deletions: deletions);
}
