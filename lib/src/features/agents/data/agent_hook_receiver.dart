import 'dart:convert';

import 'package:karmashala_core/util.dart';
import 'package:agent_cli/descriptors.dart';

/// The latest hook-reported status per `(agentId, sessionId)`. In memory only:
/// hooks describe what is happening right now, and a restart legitimately means
/// "we no longer know".
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

  /// Classifies a callback. Never throws: an unknown agent, an unrecognised
  /// event or an unparseable body all resolve to `unknown` rather than an error,
  /// because a hook must never block the agent that fired it.
  ///
  /// [observedAt] is when the agent fired, for a transport that knows. HTTP does
  /// not — the callback *is* the arrival — and leaves it null; the spool does,
  /// because a payload drained now may have been written before this app
  /// started, and stamping it "now" would announce a stale status as news.
  AgentStatusReport handle({
    required String? agentId,
    required String? event,
    required String body,
    DateTime? observedAt,
  }) {
    final id = agentId ?? '';
    final name = event ?? '';
    final spec = id.isEmpty ? null : registry.byId(id)?.hooks;
    // Decoded once and walked by path from here on: several fields come off the
    // one payload, and re-parsing per field grew the cost of a callback with how
    // much of it we understood.
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
    // A subtype the agent named and we do not recognise is `unknown`, not the
    // event's default: `Notification` defaults to `awaitingApproval`, and its
    // subtypes include a successful login and an MCP elicitation result.
    final declaredStatus = kind.isEmpty
        ? spec?.eventStatus[name] ?? AgentActivityStatus.unknown
        : declared?.status ?? AgentActivityStatus.unknown;
    // **The turn ended; the session did not.** Claude Code fires a real `Stop`
    // on the main thread the moment a `Task` subagent is launched, and wakes the
    // session with a fresh `UserPromptSubmit` when the worker reports back — so
    // trusting the event name announces "Agent finished" tens of minutes early.
    // The payload says which it is.
    final status = _inFlight(spec, name, payload)
        ? AgentActivityStatus.working
        : declaredStatus;
    // The agent's own description of what it wants or of what it just did, when
    // its hooks carry one. Decoding it only for the session id is why an
    // approval could be announced but never explained.
    final message = spec == null ? '' : _messageIn(spec, payload, declared);

    // **What the agent said about the session, not about the turn.** A subtype
    // the payload carries answers for itself, and only an event with no subtype
    // falls back to the spec's per-event table.
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
      // Only a session that stopped *for the user* has anything to be waiting
      // on. Otherwise the prose rules would run over a finished turn's own
      // summary, and an agent that wrote "it needs your permission" in a
      // sentence would have claimed an open prompt on the strength of it.
      waiting: spec == null || status != AgentActivityStatus.awaitingApproval
          ? AgentWaitKind.unrecorded
          : kind.isEmpty
          ? _waitKind(spec, message)
          : declared?.waiting ?? AgentWaitKind.unrecorded,
    );
    if (status != AgentActivityStatus.unknown) reports.record(report);
    return report;
  }

  /// What [message] says the agent is waiting on, per [spec]'s own rules. The
  /// event name cannot answer this: Claude Code's `Notification` fires both for
  /// a permission request and for a turn waiting on the user. An unmatched
  /// message stays [AgentWaitKind.unrecorded], because the fallback is what
  /// decides whether a button that types Enter is offered.
  AgentWaitKind _waitKind(AgentHookSpec spec, String message) {
    if (message.isEmpty) return AgentWaitKind.unrecorded;
    final lower = message.toLowerCase();
    for (final entry in spec.messageWaiting.entries) {
      if (lower.contains(entry.key.toLowerCase())) return entry.value;
    }
    return AgentWaitKind.unrecorded;
  }

  /// The agent's own words in [payload], per [spec]'s candidate paths — first
  /// non-empty wins, and a path that is absent on this event is not a failure.
  /// Falls back to [AgentHookMeaning.fallbackMessage] when the payload carries
  /// no prose of its own: Antigravity's event *name* is the whole message
  /// (`Execution failed`), and without it those events would reach the user as
  /// a session name alone.
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

  /// Whether [event]'s payload says work this session is waiting on is still
  /// running, per [spec]'s [AgentHookSpec.inFlightPath]. Only a **non-empty
  /// list** counts: a missing key, an empty list and any other shape all mean
  /// "nothing said so", which is the answer an agent that never sends the field
  /// has to get.
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

  /// The string at [path] in the decoded [payload], or `''` for a missing key, a
  /// non-string value or an unparseable body — all of which the caller renders
  /// as nothing rather than as a placeholder.
  ///
  /// A **list of one string** reads as that string: Antigravity sends the
  /// working directory as `workspacePaths`, a one-entry JSON array, and without
  /// this `cwdPath` reads nothing and adoption falls back to the wrong pane.
  /// Narrow on purpose — only where the path's own destination is a list whose
  /// first element is a string.
  static String _stringAt(List<String> path, Object? payload) {
    final value = _valueAt(path, payload);
    if (value is String) return value;
    if (value is List && value.isNotEmpty && value.first is String) {
      return value.first as String;
    }
    return '';
  }
}
