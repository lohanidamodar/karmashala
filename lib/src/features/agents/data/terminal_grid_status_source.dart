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
/// failed → awaitingApproval → working → idle.
///
/// **An approval is only claimed when the agent's own composer footer is not on
/// the same screen.** The matchers are plain substrings of an agent's UI, so
/// anything that puts those words on screen matches them — Claude Code's
/// rate-limit banner (`Usage limit reached · continuing automatically at 5pm ·
/// esc to cancel`, read off the shipped binary's own strings) sits above the
/// composer and then continues by itself, and an agent that merely *writes*
/// `Esc to cancel` in a message matches too. Both used to be reported as
/// approvals, and Approve types Enter, which at a composer submits whatever is
/// in it rather than confirming anything.
///
/// The corroborating fact comes from a real capture
/// (`test/features/agents/fixtures/claude-code-permission-modal.raw`): a modal
/// **replaces** the composer, so the footer that says `esc to interrupt` or
/// `shift+tab to cycle` is missing for exactly as long as a prompt is open.
/// Seeing that footer is therefore positive evidence that nothing is open over
/// it, which is what the wait-kind comment below already claimed and the
/// ordering did not honour.
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

    // The agent's own composer footer, if it is drawn. Its presence is what
    // disqualifies the approval bucket below — see the class doc.
    final composer =
        _firstMatch(rules.working, tailLines) ??
        _firstMatch(rules.idle, tailLines);

    // The wait kind travels with the bucket that matched, because only this
    // source can see the difference: an approval matcher fires on a drawn modal
    // with options, and an idle matcher fires on the agent's own "I am at my
    // prompt" footer, which is positive evidence that no modal is over it.
    for (final (status, waiting, matchers) in [
      (AgentActivityStatus.failed, AgentWaitKind.unrecorded, rules.failed),
      (
        AgentActivityStatus.awaitingApproval,
        AgentWaitKind.approval,
        rules.awaitingApproval,
      ),
      (AgentActivityStatus.working, AgentWaitKind.unrecorded, rules.working),
      (AgentActivityStatus.idle, AgentWaitKind.input, rules.idle),
    ]) {
      if (status == AgentActivityStatus.awaitingApproval && composer != null) {
        continue;
      }
      final hit = _firstMatch(matchers, tailLines);
      if (hit == null) continue;
      return AgentStatusReport(
        agentId: descriptor.id,
        sessionId: sessionId,
        status: status,
        source: AgentStatusSource.terminalGrid,
        observedAt: now,
        detail: hit,
        waiting: waiting,
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
