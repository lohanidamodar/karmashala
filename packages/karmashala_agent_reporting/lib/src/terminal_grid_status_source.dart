import 'package:agent_cli/descriptors.dart';

/// Reads an agent's status off its own terminal screen — the only source but a
/// hook that sees an approval. Matches rendered rows, never the byte stream.
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
    // disqualifies the approval bucket below — a prompt's words above a live
    // composer are text the agent printed, not a modal.
    final composerRow = _lowestRow([
      ...rules.working,
      ...rules.idle,
    ], tailLines);
    // **Unless a menu is drawn under it.** Claude Code 2.1.283 draws its
    // startup offers ("Teach auto mode about your environment?") below the
    // composer's footer, which stays on screen above them. Only the rows under
    // the lowest footer can be that modal, and only when they hold a menu the
    // agent's own menu rules read whole: a footer the agent quoted in a reply
    // is always above its composer.
    final menus = descriptor.menus;
    final belowComposer = composerRow == null
        ? null
        : tailLines.sublist(composerRow + 1);
    final modalBelow =
        belowComposer != null &&
        menus != null &&
        readScreenMenu(belowComposer, menus) != null;
    // **With no composer, a prompt still has to draw its choices.** A slash
    // command's panel takes the composer's place too — `/usage`, `/stats`,
    // `/status` — and its footer says `Esc to cancel`, which read as an
    // approval and raised the ask dock over a session nobody had asked
    // anything (owner, 2026-09-30). A permission modal, the trust modal and a
    // question all draw a menu the agent's menu rules read; those panels do
    // not. An agent with no menu rules keeps the old reading.
    final choicesDrawn =
        composerRow != null ||
        menus == null ||
        readScreenMenu(tailLines, menus) != null;

    // The wait kind travels with the bucket that matched: an approval matcher
    // fires on a drawn modal, an idle one on the agent's own prompt footer.
    for (final (status, waiting, matchers) in [
      (AgentActivityStatus.failed, AgentWaitKind.unrecorded, rules.failed),
      (
        AgentActivityStatus.awaitingApproval,
        AgentWaitKind.question,
        rules.question,
      ),
      (
        AgentActivityStatus.awaitingApproval,
        AgentWaitKind.approval,
        rules.awaitingApproval,
      ),
      (AgentActivityStatus.working, AgentWaitKind.unrecorded, rules.working),
      (AgentActivityStatus.idle, AgentWaitKind.input, rules.idle),
    ]) {
      final prompt = status == AgentActivityStatus.awaitingApproval;
      if (prompt && composerRow != null && !modalBelow) continue;
      if (prompt && !choicesDrawn) continue;
      // A prompt under a composer is read off the rows under it alone.
      final rows = prompt && modalBelow ? belowComposer : tailLines;
      final hit = _firstMatch(matchers, rows);
      if (hit == null) continue;
      return AgentStatusReport(
        agentId: descriptor.id,
        sessionId: sessionId,
        status: status,
        source: AgentStatusSource.terminalGrid,
        observedAt: now,
        detail: hit,
        waiting: waiting,
        // Only for an approval, and passed on verbatim: deciding which row is
        // "the question" would be guessing at a TUI's layout.
        evidence: prompt ? _quotable(rows) : const [],
      );
    }
    return null;
  }

  /// The index of the lowest row any of [matchers] fires on, or null.
  static int? _lowestRow(List<GridMatcher> matchers, List<String> lines) {
    for (var i = lines.length - 1; i >= 0; i--) {
      if (matchers.any((matcher) => matcher.matches(lines[i]))) return i;
    }
    return null;
  }

  /// The prompt's own rows, blank ones dropped. No interpretation: inventing a
  /// summary would describe an action the user is about to allow.
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
