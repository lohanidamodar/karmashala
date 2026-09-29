/// The branch name in the shadow git directory's `HEAD`. It never exists.
const kCheckpointHeadBranch = 'karmashala-checkpoints';

/// Who checkpoint commits are attributed to — a label, since they are never pushed.
const kCheckpointAuthorName = 'Karmashala';
const kCheckpointAuthorEmail = 'checkpoints@karmashala.local';

/// Where the private checkpoint index and its scratch patch live.
class CheckpointGitDirs {
  const CheckpointGitDirs({required this.gitDir, required this.commonDir});

  /// This working tree's own git directory. For a linked worktree that is
  /// `<repo>/.git/worktrees/<name>`, not `<repo>/.git`.
  final String gitDir;

  /// The git directory the objects and refs live in, shared by every worktree.
  final String commonDir;

  String get shadowGitDir => '$gitDir/karmashala';
  String get patchFile => '$shadowGitDir/apply.patch';
}
