import 'dart:convert';

import 'package:agent_cli/descriptors.dart';

/// **The latest tool call each conversation announced, kept until it is
/// done** — so a permission prompt that opens after it can say what it asks
/// about (the ask dock's exact command, spec §5), and when the wait began.
///
/// Read off the event an agent's [AgentQuestionSupport] already names as the
/// one carrying a tool call's name and input (`PreToolUse` on Claude Code):
/// the question and the permission prompt are both announced by it, and
/// reading the same declared paths keeps every agent-specific word in the
/// adapter. An agent that declares none — Codex, Antigravity — keeps no ask,
/// and its dock quotes the screen.
///
/// In memory only: a restart means "we no longer know", which is the honest
/// answer for a prompt nobody saw open.
class ToolAskTracker {
  ToolAskTracker({required this.agents});

  final AgentRegistry agents;
  final _asks = <String, AgentToolAsk>{};

  /// How long before a wait began its call may have been announced. The
  /// prompt follows its call at once; anything older is some earlier call's.
  static const Duration askLead = Duration(minutes: 1);

  /// Folds in one hook: [report] is what the receiver made of it, and names
  /// the conversation. **Never throws.**
  void hook({
    required String agentId,
    required String event,
    required String body,
    required AgentStatusReport report,
  }) {
    final support = agents.byId(agentId)?.questions;
    final announcing = support?.hookEvent;
    if (support == null || announcing == null) return;
    final conversation = report.sessionId;
    if (conversation.isEmpty) return;
    final key = '$agentId/$conversation';
    Object? payload;
    try {
      payload = jsonDecode(body);
    } on FormatException {
      return;
    }
    final id = _stringAt(support.hookToolUseIdPath, payload);
    if (event == announcing) {
      final name = _stringAt(support.hookToolNamePath, payload);
      // A question is answered by its own card, not approved.
      if (name.isEmpty || name == support.toolName) {
        _asks.remove(key);
        return;
      }
      final input = _valueAt(support.hookToolInputPath, payload);
      final cwdPath =
          agents.byId(agentId)?.hooks?.cwdPath ?? const <String>['cwd'];
      final cwd = _stringAt(cwdPath, payload);
      _asks[key] = AgentToolAsk(
        toolName: name,
        input: input is Map ? pruneToolInput(input) : const {},
        at: report.observedAt,
        toolUseId: id.isEmpty ? null : id,
        cwd: cwd.isEmpty ? null : cwd,
      );
      return;
    }
    // The notice about the prompt itself, or an event nobody declared: the
    // call still stands.
    if (report.status == AgentActivityStatus.awaitingApproval ||
        report.status == AgentActivityStatus.unknown) {
      return;
    }
    final held = _asks[key];
    if (held == null) return;
    // Another call finishing beside it (a parallel tool) is not this one's.
    if (id.isNotEmpty && held.toolUseId != null && id != held.toolUseId) {
      return;
    }
    _asks.remove(key);
  }

  /// A call the agent itself announced as waiting on permission, over its
  /// protocol rather than a hook.
  void note(String agentId, String conversation, AgentToolAsk ask) {
    if (conversation.isEmpty) return;
    _asks['$agentId/$conversation'] = ask;
  }

  /// Drops everything kept for [agentId]'s [conversation].
  void forget(String agentId, String conversation) =>
      _asks.remove('$agentId/$conversation');

  /// [next] with the ask it is about and when its wait began, carried over
  /// from [before] while the same wait goes on — or with both cleared once it
  /// is not waiting. [now] stands in for a wait first seen on a screen.
  AgentStatusReport decorate({
    required AgentStatusReport? before,
    required AgentStatusReport next,
    required DateTime now,
  }) {
    final asking = next.hasOpenPrompt || next.hasOpenQuestion;
    if (!asking) {
      return next.toolAsk == null && next.waitingSince == null
          ? next
          : next.withAsk();
    }
    final wasAsking =
        before != null &&
        (before.hasOpenPrompt || before.hasOpenQuestion) &&
        before.waiting == next.waiting;
    final fresh =
        next.source == AgentStatusSource.hook ||
            next.source == AgentStatusSource.protocol
        ? next.observedAt
        : now;
    var since = (wasAsking ? before.waitingSince : null) ?? fresh;
    var ask = next.hasOpenPrompt ? _askFor(next, since) : null;
    // One prompt straight after another, with no report between them that
    // was not asking: a different call is a different prompt, and its wait
    // starts now, so an answer drawn from the first cannot match the second.
    final previous = wasAsking ? before.toolAsk?.toolUseId : null;
    if (previous != null &&
        ask?.toolUseId != null &&
        ask!.toolUseId != previous) {
      since = fresh;
      ask = _askFor(next, since);
    }
    return next.withAsk(toolAsk: ask, waitingSince: since);
  }

  AgentToolAsk? _askFor(AgentStatusReport report, DateTime since) {
    final held = _asks['${report.agentId}/${report.sessionId}'];
    if (held == null) return null;
    if (held.at.isBefore(since.subtract(askLead))) return null;
    // Claude Code's notice names the tool ("…permission to use Bash"). One
    // naming another built-in tool is about a different call.
    if (!held.toolName.startsWith('mcp__')) {
      for (final line in report.evidence) {
        final named = _namesTool.firstMatch(line)?.group(1);
        if (named != null && named != held.toolName) return null;
      }
    }
    return held;
  }

  static final _namesTool = RegExp(r'permission to use ([A-Za-z]+)\b');

  static Object? _valueAt(List<String> path, Object? payload) {
    if (path.isEmpty) return null;
    var value = payload;
    for (final segment in path) {
      if (value is! Map) return null;
      value = value[segment];
    }
    return value;
  }

  static String _stringAt(List<String> path, Object? payload) =>
      switch (_valueAt(path, payload)) {
        final String value => value,
        _ => '',
      };
}
