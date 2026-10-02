import 'dart:convert';

import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_agent_reporting/hooks.dart';
import 'package:karmashala_agent_reporting/status.dart';
import 'package:karmashala_core/util.dart';

import '../domain/hosted_agent_status.dart';
import '../domain/status_evidence.dart';
import 'tool_asks.dart';

/// **What the agent in each session a host holds is doing**, kept from the two
/// things the host sees for itself: every hook the agent fires, and the screen
/// it draws. The precedence is the status service's — a fresh hook (unless it
/// says idle and a screen read since shows a prompt), then a screen showing a
/// prompt or a failure, then the rest of the screen, then the last hook
/// however old (standing in for the transcript) — with
/// every agent-specific word read from the agent's adapter, never its id.
///
/// No transcript: a host holds the process and its screen, and a hook says
/// which conversation it is in; the app's transcript fallback stays with the
/// panes no host holds. Keyed by session **row** id. Pure: the caller feeds
/// it hooks and screens and publishes what it returns.
class HostedStatusKeeper {
  HostedStatusKeeper({
    required this.agents,
    this.clock = const SystemClock(),
    Duration hookFreshness = const Duration(minutes: 5),
  }) : _reports = AgentHookReports(),
       _asks = ToolAskTracker(agents: agents) {
    _receiver = AgentHookReceiver(
      registry: agents,
      reports: _reports,
      clock: clock,
    );
    _service = AgentStatusService(
      registry: agents,
      hookReports: _reports,
      clock: clock,
      hookFreshness: hookFreshness,
    );
  }

  final AgentRegistry agents;
  final Clock clock;
  final AgentHookReports _reports;
  late final AgentHookReceiver _receiver;
  late final AgentStatusService _service;
  final _sessions = <String, _Kept>{};

  /// The tool call each conversation last announced: what an open prompt is
  /// asking about, carried on its status for the ask dock.
  final ToolAskTracker _asks;

  /// Every session row whose status is kept.
  Iterable<String> get tracked => _sessions.keys;

  bool isTracked(String sessionId) => _sessions.containsKey(sessionId);

  /// The agent running [sessionId], while it is kept.
  String? agentOf(String sessionId) => _sessions[sessionId]?.agentId;

  /// The status held for [sessionId], or null when it is not kept.
  HostedAgentStatus? statusOf(String sessionId) => _sessions[sessionId]?.status;

  /// Every status held, for a watcher that has just arrived.
  List<HostedAgentStatus> snapshot() => [
    for (final kept in _sessions.values) kept.status,
  ];

  /// Starts keeping [sessionId]'s status as [agentId] runs it, in the
  /// conversation [conversationId] when the row already names one. An agent
  /// no adapter knows is kept as `unknown`. Tracking again changes the agent
  /// or conversation and keeps what was seen.
  void track(
    String sessionId, {
    required String agentId,
    String? conversationId,
  }) {
    final kept = _sessions[sessionId];
    if (kept != null) {
      kept.agentId = agentId;
      if (conversationId != null && conversationId.isNotEmpty) {
        kept.conversationId ??= conversationId;
      }
      return;
    }
    _sessions[sessionId] = _Kept(
      sessionId: sessionId,
      agentId: agentId,
      conversationId: conversationId == null || conversationId.isEmpty
          ? null
          : conversationId,
      status: HostedAgentStatus(
        sessionId: sessionId,
        report: _unknown(agentId, conversationId ?? sessionId),
      ),
    );
  }

  /// Stops keeping [sessionId] — its process ended, or its row is gone.
  void forget(String sessionId) => _sessions.remove(sessionId);

  /// The row whose conversation [conversationId] is, for a hook that did not
  /// name its pane.
  String? sessionForConversation(String agentId, String conversationId) {
    if (conversationId.isEmpty) return null;
    for (final kept in _sessions.values) {
      if (kept.agentId == agentId && kept.conversationId == conversationId) {
        return kept.sessionId;
      }
    }
    return null;
  }

  /// How many rows of the screen [sessionId]'s agent is read from.
  int scanLinesFor(String sessionId) {
    final agentId = _sessions[sessionId]?.agentId;
    final rules = agentId == null ? null : agents.byId(agentId)?.grid;
    return rules?.scanLines ?? const AgentGridRules().scanLines;
  }

  /// Classifies one hook callback and remembers it for its conversation. Call
  /// [hookLanded] with the result once the row it is about is known.
  AgentStatusReport classify({
    required String agentId,
    required String event,
    required String body,
    DateTime? receivedAt,
  }) {
    final report = _receiver.handle(
      agentId: agentId,
      event: event,
      body: body,
      observedAt: receivedAt,
    );
    _asks.hook(agentId: agentId, event: event, body: body, report: report);
    return report;
  }

  /// Folds a classified hook into [sessionId]'s status; the new status when
  /// its evidence moved, else null. [body] is read again only for a question,
  /// which travels whole.
  HostedAgentStatus? hookLanded(
    String sessionId,
    AgentStatusReport report, {
    required String body,
  }) {
    final kept = _sessions[sessionId];
    if (kept == null) return null;
    if (report.sessionId.isNotEmpty) kept.conversationId = report.sessionId;
    // A hook repeating the word before it (Claude Code's idle nudge after its
    // `Stop`) is no news about the screen: a menu drawn in between stands.
    if (report.status != AgentActivityStatus.unknown &&
        report.status != kept.hookStatus) {
      kept.hookStatus = report.status;
      kept.hookSince = report.observedAt;
    }
    if (report.hasOpenQuestion && _isTheAgentsWord(report.source)) {
      kept.question = _questionIn(kept.agentId, body) ?? kept.question;
    }
    // The screen read at the last tick still stands beside a hook: a fresh
    // hook outranks it, and a stale one does not.
    return _recompose(kept);
  }

  /// Folds in the agent's own word about itself, sent over its protocol
  /// ([AgentStatusSource.protocol]): ranked as a hook is, and the ask it
  /// carries kept for the dock. The new status when its evidence moved.
  HostedAgentStatus? report(String sessionId, AgentStatusReport report) {
    final kept = _sessions[sessionId];
    if (kept == null) return null;
    if (report.sessionId.isNotEmpty) kept.conversationId = report.sessionId;
    _reports.record(report);
    if (report.status != AgentActivityStatus.unknown &&
        report.status != kept.hookStatus) {
      kept.hookStatus = report.status;
      kept.hookSince = report.observedAt;
    }
    final ask = report.toolAsk;
    if (ask != null) {
      _asks.note(report.agentId, report.sessionId, ask);
    } else if (!report.hasOpenPrompt) {
      _asks.forget(report.agentId, report.sessionId);
    }
    return _recompose(kept);
  }

  /// Reads [sessionId]'s screen — its bottom [tailLines] — and recomposes;
  /// the new status when its evidence moved, else null. Also where a hook
  /// that has gone stale stops being believed, so it is called on a tick.
  HostedAgentStatus? screen(String sessionId, List<String> tailLines) {
    final kept = _sessions[sessionId];
    if (kept == null) return null;
    kept.tail = tailLines;
    kept.tailAt = clock.nowUtc();
    return _recompose(kept);
  }

  HostedAgentStatus? _recompose(_Kept kept) {
    final now = clock.nowUtc();
    final query = AgentStatusQuery(
      agentId: kept.agentId,
      sessionId: kept.conversationId ?? kept.sessionId,
      terminalTailLines: kept.tail,
    );
    final AgentStatusReport next;
    if (agents.byId(kept.agentId) == null) {
      // No adapter to read a screen or a hook with; the agent's own protocol
      // report, when it sent one, still stands.
      next =
          _reports.latest(query.agentId, query.sessionId) ??
          _service.unknownFor(query, now);
    } else {
      final hook = _service.hookReport(query, now);
      // Beside a fresh hook, only a screen read since the hooks came to say
      // what they say: a menu drawn once the turn ended outranks the turn's
      // idle hook (and the idle nudges repeating it), and a screen from before
      // says nothing about what came after.
      // A tie goes to the hook: Windows' clock steps by a millisecond, so a
      // screen read just before a hook often carries the hook's own time.
      final tailAt = kept.tailAt;
      final since = hook == null
          ? null
          : (kept.hookStatus == hook.status ? kept.hookSince : null) ??
                hook.observedAt;
      final grid = since == null || (tailAt != null && tailAt.isAfter(since))
          ? _service.gridReport(query, now)
          : null;
      final composed = _service.compose(
        query: query,
        now: now,
        hook: hook,
        grid: grid,
      );
      // The last hook, however old, before "nothing is known": the app's
      // transcript fallback is not here, and an agent that stopped says so
      // once. Without this a Stop fired while nobody watched lapsed to
      // `unknown` five minutes later on any screen the grid cannot read, and
      // stayed there until the agent's next hook.
      next = composed.source == AgentStatusSource.none
          ? _reports.latest(query.agentId, query.sessionId) ?? composed
          : composed;
    }
    // A question travels only while the hook that opened it is the word.
    final hookQuestion = next.hasOpenQuestion && _isTheAgentsWord(next.source);
    if (!hookQuestion) kept.question = null;
    final before = kept.status;
    // The call an open prompt asks about, and when the wait began.
    final decorated = _asks.decorate(
      before: before.report,
      next: next,
      now: now,
    );
    final moved =
        !sameStatusEvidence(before.report, decorated) ||
        before.question?.toolUseId != kept.question?.toolUseId;
    kept.status = HostedAgentStatus(
      sessionId: kept.sessionId,
      report: decorated,
      question: kept.question,
    );
    return moved ? kept.status : null;
  }

  /// The question [agentId]'s question hook carried in [body], or null.
  AgentQuestionSet? _questionIn(String agentId, String body) {
    final support = agents.byId(agentId)?.questions;
    if (support == null) return null;
    Object? payload;
    try {
      payload = jsonDecode(body);
    } on FormatException {
      return null;
    }
    final id = _valueAt(support.hookToolUseIdPath, payload);
    return AgentQuestionSet.fromToolInput(
      id is String ? id : '',
      _valueAt(support.hookToolInputPath, payload),
    );
  }

  static Object? _valueAt(List<String> path, Object? payload) {
    if (path.isEmpty) return null;
    var value = payload;
    for (final segment in path) {
      if (value is! Map) return null;
      value = value[segment];
    }
    return value;
  }

  AgentStatusReport _unknown(String agentId, String sessionId) =>
      AgentStatusReport(
        agentId: agentId,
        sessionId: sessionId,
        status: AgentActivityStatus.unknown,
        source: AgentStatusSource.none,
        observedAt: clock.nowUtc(),
      );

  /// A hook is the agent's own word about itself; so is a report the agent
  /// sent over its protocol. A screen or state-file reading is ours.
  static bool _isTheAgentsWord(AgentStatusSource source) =>
      source == AgentStatusSource.hook || source == AgentStatusSource.protocol;
}

/// Everything kept about one session between readings.
class _Kept {
  _Kept({
    required this.sessionId,
    required this.agentId,
    required this.conversationId,
    required this.status,
  });

  final String sessionId;
  String agentId;
  String? conversationId;
  HostedAgentStatus status;
  AgentQuestionSet? question;
  List<String> tail = const [];

  /// When [tail] was read, or null before the first screen.
  DateTime? tailAt;

  /// The status the hooks last said, and since when they have said it.
  AgentActivityStatus? hookStatus;
  DateTime? hookSince;
}
