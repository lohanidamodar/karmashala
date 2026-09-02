/// Where a [SessionStats] came from.
///
/// Shown in the dialog, not just carried: a count whose origin is unknown is a
/// count nobody can argue with, and the two routes disagree about what they can
/// see. The store knows every turn a session ever had; the CLI knows what it
/// currently holds in context.
enum SessionStatsSource {
  /// Accumulated from the agent's own on-disk record, as it was read.
  localStore,

  /// Printed by the CLI itself, in answer to a command sent to its pane.
  agentOutput,
}

/// Tokens, as far as one route can account for them.
///
/// Every field is nullable and nullable means **not recorded** — never zero. A
/// route that cannot see cache accounting must say so rather than claim the
/// session used no cache, which is a different and much more interesting claim.
class TokenTally {
  const TokenTally({
    this.input,
    this.output,
    this.cacheCreated,
    this.cacheRead,
    this.reasoning,
  });

  static const unknown = TokenTally();

  /// Fresh input tokens — what was not served from cache.
  final int? input;

  final int? output;

  /// Tokens written into the prompt cache.
  final int? cacheCreated;

  /// Tokens served from the prompt cache instead of being re-sent.
  final int? cacheRead;

  /// Reasoning tokens, where the agent breaks them out.
  ///
  /// **A part of [output], not a fifth bucket** — Codex's own totals add input
  /// and output alone — so it is reported beside the others and left out of
  /// [total]. Claude Code does not break thinking out at all.
  final int? reasoning;

  bool get isUnknown =>
      input == null &&
      output == null &&
      cacheCreated == null &&
      cacheRead == null &&
      reasoning == null;

  /// The four buckets added up, or null when none of them was recorded.
  ///
  /// [reasoning] is excluded on purpose: it is already inside [output].
  int? get total {
    if (input == null &&
        output == null &&
        cacheCreated == null &&
        cacheRead == null) {
      return null;
    }
    return (input ?? 0) + (output ?? 0) + (cacheCreated ?? 0) + (cacheRead ?? 0);
  }

  @override
  bool operator ==(Object other) =>
      other is TokenTally &&
      other.input == input &&
      other.output == output &&
      other.cacheCreated == cacheCreated &&
      other.cacheRead == cacheRead &&
      other.reasoning == reasoning;

  @override
  int get hashCode =>
      Object.hash(input, output, cacheCreated, cacheRead, reasoning);

  @override
  String toString() =>
      'TokenTally(in: $input, out: $output, cacheCreated: $cacheCreated, '
      'cacheRead: $cacheRead, reasoning: $reasoning)';
}

/// What one session cost, in counts.
///
/// **No money.** A dollar figure needs a price table hardcoded into the app,
/// which drifts silently the moment a model is repriced — the known weakness of
/// every open-source usage monitor. Real quota lives elsewhere in the app; this
/// counts work.
///
/// Every field but [source] is nullable, and null means the route could not
/// supply it. The dialog renders those as "not recorded" rather than as zero.
class SessionStats {
  const SessionStats({
    required this.source,
    this.turns,
    this.replies,
    this.toolCalls,
    this.tokens = TokenTally.unknown,
    this.contextWindow,
    this.firstActivityAt,
    this.lastActivityAt,
    this.output,
  });

  final SessionStatsSource source;

  /// Prompts the user sent. Tool results are not turns: a Claude Code session
  /// records them as `user` records too, and counting them turns 213 prompts
  /// into 3,442.
  final int? turns;

  /// Model replies — one per API response, not one per rendered block.
  final int? replies;

  final int? toolCalls;

  final TokenTally tokens;

  /// The model's context window, where the agent records it. Codex writes it
  /// beside every usage record; Claude Code does not write it at all.
  final int? contextWindow;

  /// The first and last records in the session's own file.
  final DateTime? firstActivityAt;
  final DateTime? lastActivityAt;

  /// What the CLI printed, kept verbatim for [SessionStatsSource.agentOutput].
  ///
  /// Not parsed, on purpose: a TUI's layout changes with every release and a
  /// parser for it breaks on each one, while showing the frame cannot.
  final String? output;

  /// Between the first and last record — elapsed, **not** time spent working.
  /// A session resumed a month later spans a month.
  Duration? get span {
    final first = firstActivityAt, last = lastActivityAt;
    if (first == null || last == null) return null;
    final span = last.difference(first);
    return span.isNegative ? null : span;
  }

  /// Whether there is anything worth rendering beyond the provenance line.
  bool get isEmpty =>
      turns == null &&
      replies == null &&
      toolCalls == null &&
      contextWindow == null &&
      firstActivityAt == null &&
      lastActivityAt == null &&
      (output == null || output!.trim().isEmpty) &&
      tokens.isUnknown;
}

/// Where an agent's lifetime totals came from.
///
/// The distinction is not academic: one of these is current and the other can
/// be months old, and a dialog that showed both without saying which is which
/// would invite exactly the comparison that produces a bug report.
enum LifetimeStatsSource {
  /// A file the CLI rewrites only when its own stats command is run, so it is
  /// as old as the last time the user asked. Claude Code's `stats-cache.json`.
  agentCache,

  /// An index the CLI maintains as it goes, so it is current. Codex's thread
  /// table in `state_<n>.sqlite`.
  agentIndex,
}

/// Why an agent has no lifetime totals to show.
enum LifetimeStatsUnavailable {
  /// This agent keeps no lifetime aggregate at all.
  agentKeepsNoAggregate,

  /// It keeps one, but none could be read on this machine — never computed
  /// here, or not readable.
  sourceNotFound,
}

/// What an agent says it has done in total, across every session it has run.
///
/// **Read from the agent's own aggregate, never summed by this app.** Adding up
/// per-session figures across a store is how the open-source monitors arrive at
/// a number, and it is also how they arrive at a wrong one — a Codex subagent's
/// rollout can replay its parent's usage history into its own file, which
/// inflated one reported total by 91×. Anything that cannot be taken from the
/// CLI's own books is left out rather than synthesised; see [note].
class LifetimeStats {
  const LifetimeStats({
    required this.source,
    this.sessions,
    this.messages,
    this.tokens = TokenTally.unknown,
    this.totalTokens,
    this.computedAt,
    this.firstActivityAt,
    this.lastActivityAt,
    this.note,
  });

  final LifetimeStatsSource source;

  /// Sessions, conversations or threads — whatever the agent counts.
  final int? sessions;

  /// Messages, as the agent counts them. **Not** turns: an agent's own message
  /// count includes what it wrote and what its tools answered, which is a
  /// different unit from the turns counted per session. [note] says so.
  final int? messages;

  final TokenTally tokens;

  /// The one figure the source records when it records no breakdown.
  ///
  /// Separate from `tokens.total` because a source can have one without the
  /// other, and a total assembled from buckets that were never there would be
  /// a number this app invented.
  final int? totalTokens;

  /// When the source was last written, for a source that can be stale.
  final DateTime? computedAt;

  final DateTime? firstActivityAt;
  final DateTime? lastActivityAt;

  /// What this particular source will not tell us, and why — set by the reader,
  /// which is the layer that knows its own quirks, and shown verbatim.
  final String? note;

  bool get isEmpty =>
      sessions == null &&
      messages == null &&
      totalTokens == null &&
      firstActivityAt == null &&
      lastActivityAt == null &&
      tokens.isUnknown;
}
