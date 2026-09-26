import 'dart:convert';

/// Lines added and removed in a unified diff, counted here rather than asked
/// of git. The *file* count is `git status`'s — it sees untracked files.
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

/// Counts changed lines in a unified diff. Only lines inside a hunk count:
/// the `+++`/`---` headers and the no-newline marker are the difficulty.
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
