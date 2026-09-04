import 'dart:convert';

import '../../../core/util/clock.dart';
import '../domain/agent_registry.dart';
import '../domain/agent_status.dart';

/// The latest hook-reported status per `(agentId, sessionId)`.
///
/// In memory only: hooks describe what is happening right now, and a restart
/// legitimately means "we no longer know".
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

/// Turns one hook callback into a status report, with no transport concerns.
///
/// Keeping this separate from the HTTP host means the endpoint can move onto
/// the app's existing control server later without touching this logic.
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
  /// event or an unparseable body all resolve to `unknown` rather than an
  /// error, because a hook must never block the agent that fired it.
  ///
  /// [observedAt] is when the agent fired, for a transport that knows. The HTTP
  /// route does not — the callback *is* the arrival — and leaves it null, which
  /// reads the clock. The spool does: a payload drained now may have been
  /// written before this app started, and stamping it "now" would announce a
  /// stale status as news. See `AgentHookSpoolEvent.firedAt`.
  AgentStatusReport handle({
    required String? agentId,
    required String? event,
    required String body,
    DateTime? observedAt,
  }) {
    final id = agentId ?? '';
    final name = event ?? '';
    final spec = id.isEmpty ? null : registry.byId(id)?.hooks;
    final sessionId = spec == null ? '' : _sessionId(spec.sessionIdPath, body);
    // The agent's own subtype for this event, when its payload carries one.
    // Empty means it does not — every Claude Code event but `Notification`, and
    // any CLI predating the field — and then the event name is all we have.
    final kind = spec == null || spec.eventKindPath.isEmpty
        ? ''
        : _stringAt(spec.eventKindPath, body);
    final declared = kind.isEmpty ? null : spec!.eventKindMeaning[kind];
    // A subtype the agent named and we do not recognise is `unknown`, not the
    // event's default. `Notification` defaults to `awaitingApproval`, and its
    // subtypes include a successful login and an MCP elicitation result — a
    // notice nobody is waiting on must not raise "this session needs you".
    final status = kind.isEmpty
        ? spec?.eventStatus[name] ?? AgentActivityStatus.unknown
        : declared?.status ?? AgentActivityStatus.unknown;
    // The agent's own description of what it wants, when its hooks carry one.
    // Claude Code's `Notification` payload has a `message`; this used to be
    // decoded for the session id and discarded, which is why an approval could
    // be announced but never explained.
    final message = spec == null
        ? ''
        : _extractMessage(spec, body, declared);

    final report = AgentStatusReport(
      agentId: id,
      sessionId: sessionId,
      status: status,
      source: AgentStatusSource.hook,
      observedAt: observedAt ?? clock.nowUtc(),
      detail: kind.isEmpty ? (name.isEmpty ? null : name) : '$name/$kind',
      evidence: message.isEmpty ? const [] : [message],
      waiting: spec == null
          ? AgentWaitKind.unrecorded
          : kind.isEmpty
          ? _waitKind(spec, message)
          : declared?.waiting ?? AgentWaitKind.unrecorded,
    );
    if (status != AgentActivityStatus.unknown) reports.record(report);
    return report;
  }

  String _extractMessage(
    AgentHookSpec spec,
    String body,
    AgentHookMeaning? declared,
  ) {
    final candidatePaths = spec.messagePaths.isNotEmpty
        ? spec.messagePaths
        : (spec.messagePath.isNotEmpty
            ? [spec.messagePath]
            : const <List<String>>[]);
    for (final path in candidatePaths) {
      final text = _stringAt(path, body).trim();
      if (text.isNotEmpty) return text;
    }
    if (declared?.fallbackMessage != null) {
      return declared!.fallbackMessage!;
    }
    return '';
  }

  /// What [message] says the agent is waiting on, per [spec]'s own rules.
  ///
  /// The event name cannot answer this: Claude Code's `Notification` fires both
  /// for a permission request and for a turn that ended and is waiting on the
  /// user. An unmatched message stays [AgentWaitKind.unrecorded] rather than
  /// falling back to an approval, because the fallback is what decides whether
  /// a button that types Enter is offered.
  AgentWaitKind _waitKind(AgentHookSpec spec, String message) {
    if (message.isEmpty) return AgentWaitKind.unrecorded;
    final lower = message.toLowerCase();
    for (final entry in spec.messageWaiting.entries) {
      if (lower.contains(entry.key.toLowerCase())) return entry.value;
    }
    return AgentWaitKind.unrecorded;
  }

  String _sessionId(List<String> path, String body) => _stringAt(path, body);

  /// The string at [path] in the JSON [body], or `''`.
  ///
  /// Empty for a missing key, a non-string value or an unparseable body — all
  /// of which mean "the agent did not tell us", which the caller renders as
  /// nothing rather than as a placeholder.
  String _stringAt(List<String> path, String body) {
    Object? value;
    try {
      value = jsonDecode(body);
    } on FormatException {
      return '';
    }
    for (final segment in path) {
      if (value is Map) {
        value = value[segment];
      } else if (value is List) {
        final index = int.tryParse(segment);
        if (index == null || index < 0 || index >= value.length) return '';
        value = value[index];
      } else {
        return '';
      }
    }
    if (value is String) return value;
    if (value is List && value.isNotEmpty && value.first is String) {
      return value.first as String;
    }
    return '';
  }
}
