import 'dart:convert';

import 'package:karmashala_core/util.dart';
import 'package:agent_cli/descriptors.dart';

/// The latest hook-reported status per `(agentId, sessionId)`. In memory only:
/// a restart legitimately means "we no longer know".
class AgentHookReports {
  final Map<String, AgentStatusReport> _byKey = {};
  final Map<String, List<String>> _inFlight = {};

  AgentStatusReport? latest(String agentId, String sessionId) =>
      _byKey['$agentId/$sessionId'];

  void record(AgentStatusReport report) {
    if (report.sessionId.isEmpty) return;
    _byKey['${report.agentId}/${report.sessionId}'] = report;
  }

  /// The work the agent last said is still running after its turn, or empty.
  List<String> inFlight(String agentId, String sessionId) =>
      _inFlight['$agentId/$sessionId'] ?? const [];

  void _holdInFlight(String agentId, String sessionId, List<String> work) {
    if (sessionId.isEmpty) return;
    if (work.isEmpty) {
      _inFlight.remove('$agentId/$sessionId');
    } else {
      _inFlight['$agentId/$sessionId'] = work;
    }
  }

  void clear() {
    _byKey.clear();
    _inFlight.clear();
  }
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
    final tableStatus = spec?.eventStatus[name] ?? AgentActivityStatus.unknown;
    // Without a subtype, an event that says the session stopped for the user
    // is read by its prose: Claude Code's idle nudge is not a prompt.
    final declared = kind.isEmpty
        ? (tableStatus == AgentActivityStatus.awaitingApproval
              ? _proseMeaning(spec!, payload)
              : null)
        : spec!.eventKindMeaning[kind];
    // A subtype we do not recognise is `unknown`, not the event's default:
    // `Notification` covers a successful login as well as an approval.
    final declaredStatus = kind.isEmpty
        ? declared?.status ?? tableStatus
        : declared?.status ?? AgentActivityStatus.unknown;
    // The agent's own words, when its hooks carry any. Decoding them only for
    // the session id is why an approval could be announced but not explained.
    final message = spec == null ? '' : _messageIn(spec, payload, declared);

    // **What the agent said about the session, not about the turn.** A subtype
    // answers for itself; only an event without one falls back to the table.
    final declaredEnding = kind.isEmpty
        ? spec?.eventEnding[name]
        : declared?.ending;
    // A `/clear` ends the conversation, not the pane's session.
    final ending =
        declaredEnding != null &&
            spec!.endingReasonPath.isNotEmpty &&
            spec.conversationOnlyEndReasons.contains(
              _stringAt(spec.endingReasonPath, payload),
            )
        ? AgentSessionEnding.conversationOnly
        : declaredEnding;

    // **The turn ended; the session did not.** Claude Code fires a real `Stop`
    // when a `Task` subagent launches, so the payload decides, not the name.
    // Only the event that lists the work, an ending or a failure retires it.
    final listed = _inFlight(spec, name, payload);
    if (listed != null) reports._holdInFlight(id, sessionId, listed);
    if (ending != null || declaredStatus == AgentActivityStatus.failed) {
      reports._holdInFlight(id, sessionId, const []);
    }
    final inFlight = reports.inFlight(id, sessionId);
    // Its idle nudge looks only at the main thread, so while work is listed an
    // idle word means the session handed off, not that it finished.
    final backgroundOnly =
        inFlight.isNotEmpty && declaredStatus == AgentActivityStatus.idle;
    final status = backgroundOnly
        ? AgentActivityStatus.working
        : declaredStatus;

    // **A question opening.** The event that announces it is an ordinary tool
    // call to the table above, so it is recognised by the tool it names.
    final asked = _question(id, name, payload);
    if (asked != null) {
      final report = AgentStatusReport(
        agentId: id,
        sessionId: sessionId,
        status: AgentActivityStatus.awaitingApproval,
        source: AgentStatusSource.hook,
        observedAt: observedAt ?? clock.nowUtc(),
        detail: '$name/question',
        evidence: [for (final q in asked.questions) q.question],
        waiting: AgentWaitKind.question,
      );
      reports.record(report);
      return report;
    }

    final report = AgentStatusReport(
      agentId: id,
      sessionId: sessionId,
      status: status,
      source: AgentStatusSource.hook,
      observedAt: observedAt ?? clock.nowUtc(),
      detail: kind.isEmpty ? (name.isEmpty ? null : name) : '$name/$kind',
      evidence: message.isEmpty ? const [] : [message],
      ending: ending,
      failureReason: _failureReason(spec, status, payload),
      inFlight: inFlight,
      backgroundOnly: backgroundOnly,
      // Only a session that stopped *for the user* is asked: otherwise an agent
      // writing "it needs your permission" would claim an open prompt.
      waiting: status != AgentActivityStatus.awaitingApproval
          ? AgentWaitKind.unrecorded
          : declared?.waiting ?? AgentWaitKind.unrecorded,
    );
    // **The notice a question sends about itself.** Claude Code follows the
    // question's PreToolUse with a permission_prompt Notification, which on
    // its own reads as an approval — and Approve is Enter, which would answer
    // the question with whatever option is highlighted. While the session's
    // latest word is that open question, the question stands. Anything else in
    // between (its own PostToolUse included) has already replaced it.
    final before = reports.latest(id, sessionId);
    // **A subagent's event, under its parent's session id.** A background
    // agent working says nothing about the question or prompt the main
    // thread has open; only an ending or a failure outranks that.
    final fromSubagent =
        spec != null &&
        spec.subagentIdPath.isNotEmpty &&
        _stringAt(spec.subagentIdPath, payload).isNotEmpty;
    if (fromSubagent &&
        before != null &&
        before.status == AgentActivityStatus.awaitingApproval &&
        (before.waiting == AgentWaitKind.question ||
            before.waiting == AgentWaitKind.approval) &&
        ending == null &&
        status != AgentActivityStatus.failed) {
      return before;
    }
    if (report.waiting == AgentWaitKind.approval &&
        before != null &&
        before.waiting == AgentWaitKind.question &&
        before.status == AgentActivityStatus.awaitingApproval) {
      final kept = AgentStatusReport(
        agentId: before.agentId,
        sessionId: before.sessionId,
        status: before.status,
        source: before.source,
        observedAt: report.observedAt,
        detail: before.detail,
        evidence: before.evidence,
        waiting: AgentWaitKind.question,
      );
      reports.record(kept);
      return kept;
    }
    if (status != AgentActivityStatus.unknown) reports.record(report);
    return report;
  }

  /// The question [event] opens, when it is [agentId]'s question event naming
  /// its question tool with input this build can read; otherwise null.
  AgentQuestionSet? _question(String agentId, String event, Object? payload) {
    final support = registry.byId(agentId)?.questions;
    if (support == null || support.hookEvent != event) return null;
    if (_stringAt(support.hookToolNamePath, payload) != support.toolName) {
      return null;
    }
    return AgentQuestionSet.fromToolInput(
      '',
      _valueAt(support.hookToolInputPath, payload),
    );
  }

  static String? _failureReason(
    AgentHookSpec? spec,
    AgentActivityStatus status,
    Object? payload,
  ) {
    if (spec == null || status != AgentActivityStatus.failed) return null;
    if (spec.failureReasonPath.isEmpty) return null;
    final reason = _stringAt(spec.failureReasonPath, payload);
    return reason.isEmpty ? null : reason;
  }

  /// What the message in [payload] says the event means — `Notification`
  /// covers both a permission request and a finished turn — or null when no
  /// declared prose matches it.
  static AgentHookMeaning? _proseMeaning(AgentHookSpec spec, Object? payload) {
    final message = _messageIn(spec, payload, null).toLowerCase();
    if (message.isEmpty) return null;
    for (final entry in spec.messageMeaning.entries) {
      if (message.contains(entry.key.toLowerCase())) return entry.value;
    }
    return null;
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

  /// The work [event]'s payload says is still running, named; null when the
  /// event declares no such list. Only a **non-empty list** names any, so an
  /// agent that never sends the field is safe.
  static List<String>? _inFlight(
    AgentHookSpec? spec,
    String event,
    Object? payload,
  ) {
    final path = spec?.inFlightPath[event];
    if (path == null || path.isEmpty) return null;
    final value = _valueAt(path, payload);
    if (value is! List) return const [];
    return [for (final entry in value) _inFlightLabel(spec!, entry)];
  }

  static String _inFlightLabel(AgentHookSpec spec, Object? entry) {
    for (final path in spec.inFlightLabelPaths) {
      final label = _stringAt(path, entry);
      if (label.isNotEmpty) return label;
    }
    return 'background work';
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
