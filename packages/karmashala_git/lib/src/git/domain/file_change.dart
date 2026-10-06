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
    this.newFolder,
    this.moreFiles = 0,
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

  /// The untracked folder this file was found in (`lib/feature`), which git
  /// itself reports as one `? lib/feature/` entry. Null for any other file.
  final String? newFolder;

  /// For the one row that stands in for the files of [newFolder] past the
  /// listing limit, how many it stands in for; [path] is then the folder's.
  final int moreFiles;

  /// How many files this row counts for.
  int get fileCount => moreFiles > 0 ? moreFiles : 1;

  @override
  bool operator ==(Object other) =>
      other is FileChange &&
      other.path == path &&
      other.originalPath == originalPath &&
      other.type == type &&
      other.conflict == conflict &&
      other.staged == staged &&
      other.unstaged == unstaged &&
      other.newFolder == newFolder &&
      other.moreFiles == moreFiles;

  @override
  int get hashCode => Object.hash(
    path,
    originalPath,
    type,
    conflict,
    staged,
    unstaged,
    newFolder,
    moreFiles,
  );

  @override
  String toString() => 'FileChange($path, $type, staged:$staged)';
}

/// How many files [changes] stand for, counting a capped folder's rest.
int changedFileCount(Iterable<FileChange> changes) =>
    changes.fold(0, (sum, change) => sum + change.fileCount);
