/// Git, as this app reads and drives it.
///
/// Values, the porcelain v2 and unified-diff parsers, the on-disk `.git` reader
/// that answers without spawning anything, and `GitService`, which runs `git`
/// through a `CommandRunner` so one code path works locally, in WSL and over SSH.
/// Nothing here opens a database or reads a provider.
library;

export 'src/git/data/file_edit_diff.dart';
export 'src/git/data/file_edit_reader.dart';
export 'src/git/data/git_diff_parsing.dart';
export 'src/git/data/git_dir.dart';
export 'src/git/data/git_files.dart';
export 'src/git/data/git_head_reader.dart';
export 'src/git/data/git_merge_state.dart';
export 'src/git/data/git_origin_reader.dart';
export 'src/git/data/git_presence_reader.dart';
export 'src/git/data/git_probe_target.dart';
export 'src/git/data/git_service.dart';
export 'src/git/data/hunk_patch.dart';
export 'src/git/data/worktree_copier.dart';
export 'src/git/domain/diff_line.dart';
export 'src/git/domain/diff_stat.dart';
export 'src/git/domain/file_change.dart';
export 'src/git/domain/file_edit.dart';
export 'src/git/domain/git_commit.dart';
export 'src/git/domain/git_presence.dart';
export 'src/git/domain/git_worktree.dart';
export 'src/git/domain/remote_repo.dart';
export 'src/git/domain/repository_origin.dart';
export 'src/git/domain/review_order.dart';
export 'src/git/domain/review_thread.dart';
export 'src/git/domain/working_tree_status.dart';
export 'src/git/domain/worktree_creation.dart';
export 'src/git/domain/worktree_setup.dart';
