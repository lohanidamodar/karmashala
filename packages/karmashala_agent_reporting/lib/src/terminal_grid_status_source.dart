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
    // disqualifies the approval bucket below — see the class doc.
    final composer =
        _firstMatch(rules.working, tailLines) ??
        _firstMatch(rules.idle, tailLines);

    // The wait kind travels with the bucket that matched: an approval matcher
    // fires on a drawn modal, an idle one on the agent's own prompt footer.
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
        // Only for an approval, and passed on verbatim: deciding which row is
        // "the question" would be guessing at a TUI's layout.
        evidence: status == AgentActivityStatus.awaitingApproval
            ? _quotable(tailLines)
            : const [],
      );
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
