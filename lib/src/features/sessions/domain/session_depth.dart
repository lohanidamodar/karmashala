/// Reads one session's parent, or `null` for a root session or an id that names
/// nothing. The only thing [SessionDepth] needs from storage.
typedef ParentLookup = String? Function(String sessionId);

/// How far down a spawn chain a session sits, and whether another level is
/// allowed. **Walked, never stored**; a walk past [maxWalk] is a refusal.
class SessionDepth {
  const SessionDepth._(this.outcome, this.depth);

  final SessionDepthOutcome outcome;

  /// Links between this session and a root; 0 for one with no parent.
  /// Meaningless unless [outcome] is [SessionDepthOutcome.ok].
  final int depth;

  /// The deepest a spawned session may itself spawn from: 2. Beyond that a
  /// runaway costs tokens faster than anyone notices.
  static const int maxDepth = 2;

  /// Links to follow before declaring the chain broken rather than long.
  static const int maxWalk = 64;

  /// Walks up from [parentSessionId] — the parent of a session that does not
  /// exist yet — and reports where its child would sit. `null` is depth 0.
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
