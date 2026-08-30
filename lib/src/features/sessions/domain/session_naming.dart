/// What a session's Git objects are called.
///
/// Three places built these names by hand — `SessionLauncher.launch`,
/// `SessionEngine.start` and `FanOutService.mergeWinner` — each writing
/// `id.substring(0, 8)` inline. Two of them *create* the branch and worktree and
/// the third *merges* the branch, so a change to the shape in one place would
/// have silently stopped the other finding what it made. They are one decision
/// and they live here.
library;

/// The short handle a session is known by outside the database.
///
/// Eight characters of the session id: long enough to be unique in a
/// repository's worktree list, short enough to read in a branch name and a
/// directory name.
///
/// Tolerant of an id shorter than that rather than throwing — `substring(0, 8)`
/// on a short id is a `RangeError` from deep inside a launch, and a session id
/// is not this function's to validate.
String sessionShortId(String sessionId) =>
    sessionId.length <= 8 ? sessionId : sessionId.substring(0, 8);

/// The branch a session's worktree is created on, and the branch merging that
/// session's work looks for.
String sessionBranchName(String sessionId) =>
    'session/${sessionShortId(sessionId)}';

/// The worktree directory name for a session, which
/// `WorktreeService.createForSession` turns into a path.
String sessionWorktreeName(String sessionId) => sessionShortId(sessionId);
