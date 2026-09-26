/// **When a pane's CLI moves to a conversation we did not name.**
///
/// Karmashala tells Claude Code its session id at launch, and then believes it
/// for ever. But a CLI can leave that conversation while the pane lives on — a
/// `/clear`, a fork, a resume that mints a fresh id — and nothing re-checks.
/// Everything downstream then reads a transcript that stopped: the session
/// shows as finished while its agent is working.
library;

/// How long a conversation must have been silent before its pane is a
/// candidate. The same five minutes `AgentStatusService.hookFreshness` uses:
/// past it the status service already stops believing that hook.
const Duration kRebindQuietFor = Duration(minutes: 5);

/// Hook events only a conversation with a turn in it fires — Claude Code's,
/// Codex's and Antigravity's spellings. A start, an end or a notice does not
/// count: a `claude` opened and quit in a plain terminal fires those and never
/// writes a transcript, and a row pointed at it resumes nothing (2026-09-23).
const Set<String> kTurnEvents = {
  'UserPromptSubmit',
  'PreToolUse',
  'PostToolUse',
  'Stop',
  'StopFailure',
  'SubagentStop',
  'PreInvocation',
  'PostInvocation',
};

/// Whether a hook named [event] shows its conversation is real enough to move
/// a row onto.
bool hookShowsATurn(String? event) =>
    event != null && kTurnEvents.contains(event);

/// One pane the app launched, and the conversation its row names.
class BoundPane {
  const BoundPane({
    required this.sessionId,
    required this.conversationId,
    this.startedHere = false,
    this.lastHeardFrom,
    this.ended = false,
  });

  /// Our own row id — what a rebind rewrites the conversation on. The row
  /// keeps its identity, its title and its pane.
  final String sessionId;

  /// The conversation the row names today.
  final String conversationId;

  /// Whether this session was started in the directory the hook reports. False
  /// is not evidence against a pane: an agent's live directory moves.
  final bool startedHere;

  /// When [conversationId] last reported a hook, or null for one that has not
  /// reported since this launch. **Null is not "long ago"** — it is "we have
  /// not heard", which is why it counts as quiet rather than as fresh.
  final DateTime? lastHeardFrom;

  /// Whether [conversationId]'s latest hook said the session ended — the
  /// `SessionEnd` a `/clear` or `/resume` fires on the way out.
  final bool ended;
}

/// **Which row a hook naming an unknown conversation belongs to**, or null when
/// that cannot be told without guessing.
///
/// [claimedBy] is the row the hook says it was fired from — the
/// `KARMASHALA_SESSION_ID` its pane was launched with. When present it is the
/// only candidate: that row takes the conversation once its own has ended or
/// gone quiet, and no other row ever does. A child agent run inside the pane
/// inherits the same id, which is why the pane's own conversation still being
/// live refuses it.
///
/// Without it, by elimination from [panes]:
///
/// 1. A pane whose conversation reported **after** the unknown one first did
///    ([firstHeardAt]) is not it: both are alive at once.
/// 2. A pane in the hook's own directory settles it, quiet or not: when some
///    pane was started there, only those may take it (2026-09-20).
/// 3. A pane whose conversation ended is the one that moved.
/// 4. A pane that was active moments ago and has been silent since may be the
///    one that moved, so while one exists **no quiet pane is chosen** — that
///    was the 2026-09-21 theft, where the pane that `/clear`ed was excluded for
///    having been active and an idle neighbour took its conversation.
/// 5. Exactly one survivor, or nothing.
String? sessionToRebind({
  required List<BoundPane> panes,
  required DateTime now,
  DateTime? firstHeardAt,
  String? claimedBy,
  Duration quietFor = kRebindQuietFor,
}) {
  bool quiet(BoundPane pane) =>
      pane.lastHeardFrom == null ||
      now.difference(pane.lastHeardFrom!) >= quietFor;

  if (claimedBy != null) {
    final claimed = [
      for (final pane in panes)
        if (pane.sessionId == claimedBy) pane,
    ];
    if (claimed.length != 1) return null;
    final pane = claimed.single;
    return pane.ended || quiet(pane) ? pane.sessionId : null;
  }

  final since = firstHeardAt ?? now;
  final notConcurrent = [
    for (final pane in panes)
      if (pane.ended ||
          pane.lastHeardFrom == null ||
          !pane.lastHeardFrom!.isAfter(since))
        pane,
  ];
  final pool = panes.any((pane) => pane.startedHere)
      ? [
          for (final pane in notConcurrent)
            if (pane.startedHere) pane,
        ]
      : notConcurrent;
  if (pool.isEmpty) return null;

  final ended = [
    for (final pane in pool)
      if (pane.ended) pane,
  ];
  if (ended.isNotEmpty) {
    return ended.length == 1 ? ended.single.sessionId : null;
  }
  if (pool.any((pane) => !quiet(pane))) return null;
  return pool.length == 1 ? pool.single.sessionId : null;
}
