/// How a file changed in the working tree, as reported by `git status`.
enum FileChangeType {
  added,
  modified,
  deleted,
  renamed,
  copied,
  untracked,

  /// An unmerged path: a merge, rebase, cherry-pick or stash-apply stopped on
  /// this file and both sides are still in the index.
  ///
  /// Its own value rather than [unknown] because it is the one status that is not
  /// a change the user made. v1 spelled it `UU` and friends, which rendered as
  /// *"changed (unrecognised git status)"* until this enum had a word for it.
  conflicted,

  unknown,
}

/// Which way a merge conflicted, from the `<XY>` of a `--porcelain=v2` `u`
/// record.
///
/// The seven pairs are git's own (`git-status(1)`, *Unmerged entries*), kept
/// apart because they need different actions.
enum MergeConflict {
  /// `DD` — both deleted.
  bothDeleted('both deleted'),

  /// `AU` — added by us, and they did not add it.
  addedByUs('added by us'),

  /// `UD` — deleted by them.
  deletedByThem('deleted by them'),

  /// `UA` — added by them.
  addedByThem('added by them'),

  /// `DU` — deleted by us.
  deletedByUs('deleted by us'),

  /// `AA` — both added.
  bothAdded('both added'),

  /// `UU` — both modified. The ordinary conflict.
  bothModified('both modified'),

  /// A pair git writes that is not one of the seven above. Named rather than
  /// guessed: inventing a side would be a claim about whose work is at stake.
  unrecorded('unmerged');

  const MergeConflict(this.words);

  /// How it reads in a sentence, in git's own vocabulary.
  final String words;

  /// The pair as `<XY>` spells it, or [unrecorded].
  static MergeConflict ofCode(String xy) => switch (xy) {
    'DD' => bothDeleted,
    'AU' => addedByUs,
    'UD' => deletedByThem,
    'UA' => addedByThem,
    'DU' => deletedByUs,
    'AA' => bothAdded,
    'UU' => bothModified,
    _ => unrecorded,
  };
}

/// A single changed path in a repository's working tree.
class FileChange {
  const FileChange({
    required this.path,
    required this.type,
    required this.staged,
    required this.unstaged,
    this.originalPath,
    this.conflict,
  });

  /// Path relative to the repository root (the new path for renames).
  final String path;

  /// For renames/copies, the original path; otherwise `null`.
  final String? originalPath;

  final FileChangeType type;

  /// Which way this path conflicted, for a [FileChangeType.conflicted] row.
  /// Null for every other type, and never inferred from anything but a `u`
  /// record's own `<XY>`.
  final MergeConflict? conflict;

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
      other.conflict == conflict &&
      other.staged == staged &&
      other.unstaged == unstaged;

  @override
  int get hashCode =>
      Object.hash(path, originalPath, type, conflict, staged, unstaged);

  @override
  String toString() => 'FileChange($path, $type, staged:$staged)';
}
