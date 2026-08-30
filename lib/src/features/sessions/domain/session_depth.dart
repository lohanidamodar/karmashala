/// Reads one session's parent, or `null` for a root session or an id that names
/// nothing. The only thing [SessionDepth] needs from storage.
typedef ParentLookup = String? Function(String sessionId);

/// How far down a spawn chain a session sits, and whether another level is
/// allowed.
///
/// ## Why the depth is walked and never stored
///
/// dray caps spawn depth at 2 — a spawned session may spawn, its children may
/// not — and derives it by walking `parent_session_id` rather than reading a
/// number:
///
/// > *"Walked off `parent_session_id` rather than stored as a number, so there
/// > is no depth field free to disagree with the chain it describes."*
///
/// A stored depth is a second source of truth. It is written once, at creation,
/// from whatever the caller believed at the time, and nothing ever revisits it —
/// so a re-parented session, a restored row, or a bug in one creation path
/// leaves a number that outlives the chain it claims to summarise, and the cap
/// silently stops meaning what it says. The chain itself cannot drift from
/// itself.
///
/// The cost is real and accepted: one row read per level, on a path that is
/// already creating a session and launching a process.
///
/// ## The cycle guard
///
/// A parent chain should be acyclic by construction — a session's parent always
/// exists before it does. [maxWalk] does not trust that, because the failure it
/// prevents is not a wrong answer but a **hang**: a cycle would spin this loop
/// forever inside the caller's turn. dray's comment is the whole argument:
///
/// > *"Cheap insurance: a cycle here would hang the caller's turn rather than
/// > fail it."*
///
/// So a walk that runs past [maxWalk] links is reported as
/// [SessionDepthOutcome.cycle] — which the caller must treat as a refusal, not
/// as depth 0.
class SessionDepth {
  const SessionDepth._(this.outcome, this.depth);

  final SessionDepthOutcome outcome;

  /// Links between this session and a root. A session with no parent is 0.
  ///
  /// Meaningless unless [outcome] is [SessionDepthOutcome.ok].
  final int depth;

  /// The deepest a spawned session may itself spawn from.
  ///
  /// 2, matching dray: a session started by the user (depth 0) may spawn
  /// (children at depth 1), those children may spawn (depth 2), and a depth-2
  /// session may not. One level of fan-out beyond the first is enough to be
  /// useful and bounded; beyond that a runaway costs tokens and machine load
  /// faster than anyone notices.
  static const int maxDepth = 2;

  /// Links to follow before declaring the chain broken rather than long.
  static const int maxWalk = 64;

  /// Walks up from [parentSessionId] — the parent of a session that does not
  /// exist yet — and reports where its child would sit.
  ///
  /// Passing `null` means "started by the user", which is depth 0.
  static SessionDepth forChildOf(String? parentSessionId, ParentLookup parent) {
    if (parentSessionId == null) {
      return const SessionDepth._(SessionDepthOutcome.ok, 0);
    }
    final seen = <String>{};
    var current = parentSessionId;
    var depth = 1;
    for (var step = 0; step < maxWalk; step++) {
      if (!seen.add(current)) {
        return const SessionDepth._(SessionDepthOutcome.cycle, 0);
      }
      final next = parent(current);
      if (next == null) {
        return depth > maxDepth
            ? SessionDepth._(SessionDepthOutcome.tooDeep, depth)
            : SessionDepth._(SessionDepthOutcome.ok, depth);
      }
      current = next;
      depth++;
    }
    // Longer than any real chain: treat it as broken rather than walk on.
    return const SessionDepth._(SessionDepthOutcome.cycle, 0);
  }

  bool get isAllowed => outcome == SessionDepthOutcome.ok;

  /// What to tell the agent that asked. Phrased for a model reading a tool
  /// error: it says what happened and that retrying will not help.
  String get refusal => switch (outcome) {
    SessionDepthOutcome.ok => '',
    SessionDepthOutcome.tooDeep =>
      'Agent-spawned sessions are limited to $maxDepth levels deep and this '
          'would be level $depth. Do the work in this session instead of '
          'delegating it further.',
    SessionDepthOutcome.cycle =>
      'This session\'s parent chain does not terminate, so its depth cannot be '
          'established. Refusing to start another session rather than '
          'guessing.',
  };
}

enum SessionDepthOutcome {
  /// Within the cap. [SessionDepth.depth] is the real depth.
  ok,

  /// The chain is sound and too long.
  tooDeep,

  /// The chain does not terminate. A refusal, never a depth.
  cycle,
}
