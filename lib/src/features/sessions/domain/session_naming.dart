/// What a session's Git objects are called.
///
/// Three places built these names by hand, each writing `id.substring(0, 8)`
/// inline: two *create* the branch and worktree and the third *merges* the
/// branch, so a change to the shape in one would silently have stopped the
/// other finding what it made.
library;

/// The short handle a session is known by outside the database: eight
/// characters of the session id. Tolerant of a shorter id rather than throwing
/// — `substring(0, 8)` on one is a `RangeError` from deep inside a launch, and
/// a session id is not this function's to validate.
String sessionShortId(String sessionId) =>
    sessionId.length <= 8 ? sessionId : sessionId.substring(0, 8);

/// The branch a session's worktree is created on, and the branch merging that
/// session's work looks for.
String sessionBranchName(String sessionId) =>
    'session/${sessionShortId(sessionId)}';

/// The worktree directory name for a session, which
/// `WorktreeService.createForSession` turns into a path.
String sessionWorktreeName(String sessionId) => sessionShortId(sessionId);
