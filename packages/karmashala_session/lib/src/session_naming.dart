/// What a session's Git objects are called. Three places built these by hand,
/// two creating the branch and one merging it — one shape, one file.
library;

/// The short handle a session is known by outside the database: eight
/// characters. Tolerant of a shorter id — a `RangeError` mid-launch is worse.
String sessionShortId(String sessionId) =>
    sessionId.length <= 8 ? sessionId : sessionId.substring(0, 8);

/// The branch a session's worktree is created on, and the branch merging that
/// session's work looks for.
String sessionBranchName(String sessionId) =>
    'session/${sessionShortId(sessionId)}';

/// The worktree directory name for a session, which
/// `WorktreeService.createForSession` turns into a path.
String sessionWorktreeName(String sessionId) => sessionShortId(sessionId);
