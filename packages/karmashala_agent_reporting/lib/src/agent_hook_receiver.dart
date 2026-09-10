import 'dart:convert';

import 'package:karmashala_core/util.dart';
import 'package:agent_cli/descriptors.dart';

/// The latest hook-reported status per `(agentId, sessionId)`. In memory only:
/// a restart legitimately means "we no longer know".
class AgentHookReports {
  final Map<String, AgentStatusReport> _byKey = {};

  AgentStatusReport? latest(String agentId, String sessionId) =>
      _byKey['$agentId/$sessionId'];

  void record(AgentStatusReport report) {
    if (report.sessionId.isEmpty) return;
    _byKey['${report.agentId}/${report.sessionId}'] = report;
  }

  void clear() => _byKey.clear();
}

/// Turns one hook callback into a status report, with no transport concerns, so
/// the endpoint can move onto the app's control server without touching this.
class AgentHookReceiver {
  AgentHookReceiver({
    required this.registry,
    required this.reports,
    required this.clock,
  });

  final AgentRegistry registry;
  final AgentHookReports reports;
  final Clock clock;

  /// Classifies a callback; never throws, because a hook must not block the
  /// agent. [observedAt] is the spool's real fire time — HTTP leaves it null.
  AgentStatusReport handle({
    required String? agentId,
    required String? event,
    required String body,
    DateTime? observedAt,
  }) {
    final id = agentId ?? '';
    final name = event ?? '';
    final spec = id.isEmpty ? null : registry.byId(id)?.hooks;
    // Decoded once and walked by path: several fields come off the one payload,
    // and re-parsing per field grew a callback's cost with what we understood.
    final payload = _decode(body);
    final sessionId = spec == null
        ? ''
        : _stringAt(spec.sessionIdPath, payload);
    // The agent's own subtype for this event, when the payload carries one.
    // Empty means it does not, and then the event name is all we have.
    final kind = spec == null || spec.eventKindPath.isEmpty
        ? ''
        : _stringAt(spec.eventKindPath, payload);
    final declared = kind.isEmpty ? null : spec!.eventKindMeaning[kind];
    // A subtype we do not recognise is `unknown`, not the event's default:
    // `Notification` covers a successful login as well as an approval.
    final declaredStatus = kind.isEmpty
        ? spec?.eventStatus[name] ?? AgentActivityStatus.unknown
        : declared?.status ?? AgentActivityStatus.unknown;
    // **The turn ended; the session did not.** Claude Code fires a real `Stop`
    // when a `Task` subagent launches, so the payload decides, not the name.
    final status = _inFlight(spec, name, payload)
        ? AgentActivityStatus.working
        : declaredStatus;
    // The agent's own words, when its hooks carry any. Decoding them only for
    // the session id is why an approval could be announced but not explained.
    final message = spec == null ? '' : _messageIn(spec, payload, declared);

    // **What the agent said about the session, not about the turn.** A subtype
    // answers for itself; only an event without one falls back to the table.
    final ending = kind.isEmpty ? spec?.eventEnding[name] : declared?.ending;

    final report = AgentStatusReport(
      agentId: id,
      sessionId: sessionId,
      status: status,
      source: AgentStatusSource.hook,
      observedAt: observedAt ?? clock.nowUtc(),
      detail: kind.isEmpty ? (name.isEmpty ? null : name) : '$name/$kind',
      evidence: message.isEmpty ? const [] : [message],
      ending: ending,
      // Only a session that stopped *for the user* is asked: otherwise an agent
      // writing "it needs your permission" would claim an open prompt.
      waiting: spec == null || status != AgentActivityStatus.awaitingApproval
          ? AgentWaitKind.unrecorded
          : kind.isEmpty
          ? _waitKind(spec, message)
          : declared?.waiting ?? AgentWaitKind.unrecorded,
    );
    if (status != AgentActivityStatus.unknown) reports.record(report);
    return report;
  }

  /// What [message] says the agent is waiting on — `Notification` covers both a
  /// permission request and a finished turn, so no match means `unrecorded`.
  AgentWaitKind _waitKind(AgentHookSpec spec, String message) {
    if (message.isEmpty) return AgentWaitKind.unrecorded;
    final lower = message.toLowerCase();
    for (final entry in spec.messageWaiting.entries) {
      if (lower.contains(entry.key.toLowerCase())) return entry.value;
    }
    return AgentWaitKind.unrecorded;
  }

  /// The agent's own words in [payload], first non-empty path winning, else
  /// [AgentHookMeaning.fallbackMessage]: Antigravity's name *is* its message.
  static String _messageIn(
    AgentHookSpec spec,
    Object? payload,
    AgentHookMeaning? declared,
  ) {
    for (final path in spec.messagePaths) {
      final value = _stringAt(path, payload);
      if (value.isNotEmpty) return value;
    }
    return declared?.fallbackMessage ?? '';
  }

  /// Whether [event]'s payload says awaited work is still running. Only a
  /// **non-empty list** counts, so an agent that never sends the field is safe.
  static bool _inFlight(AgentHookSpec? spec, String event, Object? payload) {
    final path = spec?.inFlightPath[event];
    if (path == null || path.isEmpty) return false;
    final value = _valueAt(path, payload);
    return value is List && value.isNotEmpty;
  }

  /// The hook body as JSON, or `null` when it is not JSON at all — which means
  /// "the agent did not tell us" for every field at once.
  static Object? _decode(String body) {
    try {
      return jsonDecode(body);
    } on FormatException {
      return null;
    }
  }

  /// The value at [path] in the decoded [payload], or `null`.
  static Object? _valueAt(List<String> path, Object? payload) {
    var value = payload;
    for (final segment in path) {
      if (value is! Map) return null;
      value = value[segment];
    }
    return value;
  }

  /// The string at [path], or `''` when the agent did not tell us. A **list of
  /// one string** reads as that string — Antigravity's `workspacePaths` array.
  static String _stringAt(List<String> path, Object? payload) {
    final value = _valueAt(path, payload);
    if (value is String) return value;
    if (value is List && value.isNotEmpty && value.first is String) {
      return value.first as String;
    }
    return '';
  }
}
