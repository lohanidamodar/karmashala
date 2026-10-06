import 'dart:convert';

import 'package:agent_cli/usage.dart'
    show ReportedCost, SessionStats, SessionStatsSource;
import 'package:karmashala_session_engine/store.dart'
    show SessionMessage, SessionMessageRole, SessionUsage;

/// **An ACP session's counts, from what this server kept of it**: turns and
/// tool calls from its `session_messages` rows, and the context and cost
/// from the agent's own `usage_update`s. The protocol carries no per-turn
/// input or output tokens, so the tally stays unknown rather than invented.
SessionStats acpSessionStats({
  required List<SessionMessage> rows,
  SessionUsage? usage,
}) {
  var turns = 0;
  var replies = 0;
  var toolCalls = 0;
  final byName = <String, int>{};
  DateTime? first, last;
  for (final row in rows) {
    first ??= row.createdAt;
    if (last == null || row.updatedAt.isAfter(last)) last = row.updatedAt;
    switch (row.role) {
      case SessionMessageRole.user:
        turns++;
      case SessionMessageRole.agent:
        if (row.text.isNotEmpty) replies++;
      case SessionMessageRole.tool:
        toolCalls++;
        final name = _toolName(row.toolJson);
        if (name != null) byName[name] = (byName[name] ?? 0) + 1;
      case SessionMessageRole.notice || SessionMessageRole.error:
        break;
    }
  }
  final cost = usage?.costAmount;
  return SessionStats(
    source: SessionStatsSource.agentReported,
    turns: turns,
    replies: replies,
    toolCalls: toolCalls,
    toolCallsByName: byName,
    firstActivityAt: first,
    lastActivityAt: last,
    contextWindow: usage?.contextSize,
    lastPromptTokens: usage?.contextUsed,
    contextUsedPerTurn: usage == null || usage.turns.isEmpty
        ? null
        : [for (final turn in usage.turns) turn.contextUsed],
    reportedCost: cost == null
        ? null
        : ReportedCost(amount: cost, currency: usage!.costCurrency ?? ''),
  );
}

/// The tool's `name`, else its `title`, off the row's JSON; null for neither.
String? _toolName(String? toolJson) {
  if (toolJson == null) return null;
  Object? decoded;
  try {
    decoded = jsonDecode(toolJson);
  } on FormatException {
    return null;
  }
  if (decoded is! Map) return null;
  final name = decoded['name'] ?? decoded['title'];
  return name is String && name.isNotEmpty ? name : null;
}
