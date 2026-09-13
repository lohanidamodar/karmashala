/// **When a pane's CLI moves to a conversation we did not name.**
///
/// Karmashala tells Claude Code its session id at launch, and then believes it
/// for ever. But a CLI can leave that conversation while the pane lives on — a
/// `/clear`, a fork, a resume that mints a fresh id — and nothing re-checks.
/// Everything downstream then reads a transcript that stopped: the session
/// shows as finished while its agent is working.
///
/// Measured on the owner's machine 2026-09-13: the pane titled `karmashala-2`
/// was bound to a conversation whose file had not been written for two and a
/// half hours, while the conversation it was really on had never been seen.
library;

/// How long a conversation must have been silent before its pane is a
/// candidate. The same five minutes `AgentStatusService.hookFreshness` uses:
/// past it the status service already stops believing that hook.
const Duration kRebindQuietFor = Duration(minutes: 5);

/// One pane the app launched, and the conversation its row names.
class BoundPane {
  const BoundPane({
    required this.sessionId,
    required this.conversationId,
    this.startedHere = false,
    this.lastHeardFrom,
  });

  /// Our own row id — what a rebind rewrites the conversation on. The row
  /// keeps its identity, its title and its pane.
  final String sessionId;

  /// The conversation the row names today.
  final String conversationId;

  /// Whether this session was started in the directory the hook reports. A
  /// tie-break, and false is not evidence against a pane: an agent's live
  /// directory moves during a session.
  final bool startedHere;

  /// When [conversationId] last reported a hook, or null for one that has not
  /// reported since this launch. **Null is not "long ago"** — it is "we have
  /// not heard", which is why it counts as quiet rather than as fresh.
  final DateTime? lastHeardFrom;
}

/// **Which row a hook naming an unknown conversation belongs to**, or null when
/// that cannot be told without guessing.
///
/// Three rules, in order:
///
/// 1. A pane whose own conversation is still reporting is not it. That is the
///    decisive one: two panes running the same agent in the same folder are
///    told apart by which of them has gone quiet, which no directory or title
///    comparison can do.
/// 2. When any quiet pane was started in the directory the hook reports, only
///    those are considered. A tie-break, never a filter on its own: an agent's
///    *live* directory moves during a session, so a mismatch is not evidence.
/// 3. Exactly one survivor, or nothing. Re-pointing the wrong row would put
///    one session's transcript under another's name, which is worse than the
///    stale reading this fixes.
String? sessionToRebind({
  required List<BoundPane> panes,
  required DateTime now,
  Duration quietFor = kRebindQuietFor,
}) {
  final quiet = [
    for (final pane in panes)
      if (pane.lastHeardFrom == null ||
          now.difference(pane.lastHeardFrom!) >= quietFor)
        pane,
  ];
  if (quiet.isEmpty) return null;
  final here = [
    for (final pane in quiet)
      if (pane.startedHere) pane,
  ];
  final considered = here.isEmpty ? quiet : here;
  return considered.length == 1 ? considered.single.sessionId : null;
}
