/// Worktree cleanup: the rules a person sets (off unless turned on), the
/// refusals checked before anything is removed, and what a sweep or a preview
/// reports. The sweep itself runs in the server, on its own schedule.
library;

export 'src/git/cleanup/worktree_cleanup_policy.dart';
export 'src/git/cleanup/worktree_cleanup_report.dart';
