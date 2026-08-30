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
  AgentStatusReport handle({
    required String? agentId,
    required String? event,
    required String body,
  }) {
    final id = agentId ?? '';
    final name = event ?? '';
    final spec = id.isEmpty ? null : registry.byId(id)?.hooks;
    final status = spec?.eventStatus[name] ?? AgentActivityStatus.unknown;
    final sessionId = spec == null ? '' : _sessionId(spec.sessionIdPath, body);
    // The agent's own description of what it wants, when its hooks carry one.
    // Claude Code's `Notification` payload has a `message`; this used to be
    // decoded for the session id and discarded, which is why an approval could
    // be announced but never explained.
    final message = spec == null || spec.messagePath.isEmpty
        ? ''
        : _stringAt(spec.messagePath, body);

    final report = AgentStatusReport(
      agentId: id,
      sessionId: sessionId,
      status: status,
      source: AgentStatusSource.hook,
      observedAt: clock.nowUtc(),
      detail: name.isEmpty ? null : name,
      evidence: message.isEmpty ? const [] : [message],
    );
    if (status != AgentActivityStatus.unknown) reports.record(report);
    return report;
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
      if (value is! Map) return '';
      value = value[segment];
    }
    return value is String ? value : '';
  }
}
