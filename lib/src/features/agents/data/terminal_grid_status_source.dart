import '../domain/agent_descriptor.dart';
import '../domain/agent_status.dart';

/// Orca's third status source: read the agent's status off the bottom of its own
/// terminal screen.
///
/// This is the only source available to an agent with neither installed hooks
/// nor a state file we can parse — which, once any registry agent can run in a
/// PTY, is most of them. It is also the only source besides hooks that can see
/// [AgentActivityStatus.awaitingApproval], because an approval prompt is drawn
/// on screen and never written to a transcript in a form worth trusting.
///
/// ## What it will and will not claim
///
/// The input is already narrowed to the last handful of rows (see
/// `terminalTailLines`), which is what keeps a phrase that scrolled past from
/// being read as a live prompt. Within that window the order is
/// failed → awaitingApproval → working → idle, so a prompt drawn over a spinner
/// reads as waiting for the user rather than as busy.
///
/// **It matches rendered characters, never the byte stream.** Both shipped
/// agents position words with cursor-movement escapes rather than spaces, so
/// `esc to interrupt` does not exist as a substring anywhere in the PTY output —
/// it only exists once a VT parser has placed those words in columns. A source
/// that regexed the raw stream would silently never match.
///
/// Returns `null` — not a status — when nothing matches, so the caller can fall
/// through to another source rather than being told a wrong answer.
class TerminalGridStatusSource {
  const TerminalGridStatusSource();

  AgentStatusReport? read(
    AgentDescriptor descriptor,
    List<String> tailLines,
    DateTime now, {
    required String sessionId,
  }) {
    final rules = descriptor.grid;
    if (rules.isEmpty || tailLines.isEmpty) return null;

    for (final (status, matchers) in [
      (AgentActivityStatus.failed, rules.failed),
      (AgentActivityStatus.awaitingApproval, rules.awaitingApproval),
      (AgentActivityStatus.working, rules.working),
      (AgentActivityStatus.idle, rules.idle),
    ]) {
      final hit = _firstMatch(matchers, tailLines);
      if (hit == null) continue;
      return AgentStatusReport(
        agentId: descriptor.id,
        sessionId: sessionId,
        status: status,
        source: AgentStatusSource.terminalGrid,
        observedAt: now,
        detail: hit,
        // Only for an approval, and only the rows themselves.
        //
        // `detail` is the matcher that fired — `Enter to confirm` — which
        // explains the verdict and says nothing about what is being asked. The
        // rows that produced it do, and they were already in scope and thrown
        // away. Carrying them for `working`/`idle` too would put a screenful of
        // text through a 1.2-second poll to describe a spinner.
        //
        // Passed on verbatim and never parsed. Deciding which of these rows is
        // "the question" would be guessing at a TUI's layout, and a wrong guess
        // here misdescribes what the user is about to authorise.
        evidence: status == AgentActivityStatus.awaitingApproval
            ? _quotable(tailLines)
            : const [],
      );
    }
    return null;
  }

  /// The prompt's own rows, blank ones dropped, in screen order.
  ///
  /// No interpretation: whatever the agent drew is what the user is shown, over
  /// a label saying it came from the terminal. Quoting a screen is the only
  /// honest way this source can answer "what is being approved" — it has no
  /// structured record to consult, and inventing a summary from these rows
  /// would describe an action the user is about to allow.
  static List<String> _quotable(List<String> tailLines) => [
    for (final line in tailLines)
      if (line.trim().isNotEmpty) line.trimRight(),
  ];

  /// The matcher that fired, described well enough to explain the verdict in a
  /// tooltip or a log line.
  String? _firstMatch(List<GridMatcher> matchers, List<String> lines) {
    for (final matcher in matchers) {
      for (final line in lines) {
        if (matcher.matches(line)) return matcher.contains;
      }
    }
    return null;
  }
}
