/// Making and removing worktrees: the staged creation (fetch, checkout,
/// submodules, the repository's own setup, the agent), its live record and
/// cancel, the setup and teardown a repository asks for, and the table those
/// verdicts are kept in.
///
/// Pure Dart: where a worktree's commands run is a callback, and a setup
/// command's visible terminal is the caller's to open — the desktop app opens
/// a pane, the session host a session of its own.
library;

export 'src/git/service/worktree_creation_tracker.dart';
export 'src/git/service/worktree_service.dart';
export 'src/git/service/worktree_setup_service.dart';
export 'src/git/store/worktree_setup_dao.dart';
