/// Lines added and removed in a checkout, as `git diff --numstat` reports them.
///
/// Distinct from the fan-out's `DiffLineCounts`, which counts `+`/`-` lines in
/// diff text it already had in hand. This one comes from git directly, so it
/// also knows how many files it covered and how many of those were binary —
/// numbers a text count cannot produce.
class DiffStat {
  const DiffStat({
    required this.added,
    required this.removed,
    required this.files,
    this.binaryFiles = 0,
  });

  static const none = DiffStat(added: 0, removed: 0, files: 0);

  final int added;
  final int removed;

  /// Files the diff touched, binary ones included.
  final int files;

  /// Files git reported as binary (`-` in place of a count). Their bytes
  /// changed but no line did, so they are counted here and nowhere else.
  final int binaryFiles;

  bool get isEmpty => added == 0 && removed == 0 && files == 0;

  @override
  bool operator ==(Object other) =>
      other is DiffStat &&
      other.added == added &&
      other.removed == removed &&
      other.files == files &&
      other.binaryFiles == binaryFiles;

  @override
  int get hashCode => Object.hash(added, removed, files, binaryFiles);

  @override
  String toString() => 'DiffStat(+$added -$removed over $files files)';
}

/// How two refs stand relative to one another: commits [ahead] that the base
/// does not have, and commits [behind] that it has and we do not.
class AheadBehind {
  const AheadBehind({required this.ahead, required this.behind});

  static const same = AheadBehind(ahead: 0, behind: 0);

  final int ahead;
  final int behind;

  bool get isUpToDate => ahead == 0 && behind == 0;

  @override
  bool operator ==(Object other) =>
      other is AheadBehind && other.ahead == ahead && other.behind == behind;

  @override
  int get hashCode => Object.hash(ahead, behind);

  @override
  String toString() => 'AheadBehind(ahead $ahead, behind $behind)';
}
