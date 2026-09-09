import 'dart:convert';

import 'package:karmashala_core/util.dart';
import 'package:agent_cli/descriptors.dart';

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
    // Decoded once and walked by path from here on. Several fields are read off
    // the one payload, and re-parsing it per field made the cost of a callback
    // grow with how much of it we learned to understand.
    final payload = _decode(body);
    final sessionId = spec == null
        ? ''
        : _stringAt(spec.sessionIdPath, payload);
    // The agent's own subtype for this event, when its payload carries one.
    // Empty means it does not — every Claude Code event but `Notification`, and
    // any CLI predating the field — and then the event name is all we have.
    final kind = spec == null || spec.eventKindPath.isEmpty
        ? ''
        : _stringAt(spec.eventKindPath, payload);
    final declared = kind.isEmpty ? null : spec!.eventKindMeaning[kind];
    // A subtype the agent named and we do not recognise is `unknown`, not the
    // event's default. `Notification` defaults to `awaitingApproval`, and its
    // subtypes include a successful login and an MCP elicitation result — a
    // notice nobody is waiting on must not raise "this session needs you".
    final declaredStatus = kind.isEmpty
        ? spec?.eventStatus[name] ?? AgentActivityStatus.unknown
        : declared?.status ?? AgentActivityStatus.unknown;
    // **The turn ended; the session did not.** Claude Code fires a real `Stop`
    // on the main thread the moment a `Task` subagent is launched, and wakes
    // the session with a fresh `UserPromptSubmit` when the worker reports back
    // — so a hook stream that trusts the event name announces "Agent finished"
    // in the middle of a turn, minutes or tens of minutes early. The payload
    // says which it is, and that is the field this consults.
    final status = _inFlight(spec, name, payload)
        ? AgentActivityStatus.working
        : declaredStatus;
    // The agent's own description of what it wants or of what it just did, when
    // its hooks carry one. This used to be decoded for the session id and
    // discarded, which is why an approval could be announced but never
    // explained; reading only `message` then left every finished turn with a
    // session name and nothing else.
    final message = spec == null ? '' : _messageIn(spec, payload, declared);

    // **What the agent said about the session, not about the turn.** Same
    // division as the status above: a subtype the payload carries answers for
    // itself, and only an event with no subtype falls back to the spec's own
    // per-event table.
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
      // on, so nothing else is asked the question. Without that guard the prose
      // rules would run over a finished turn's own summary, and an agent that
      // wrote "it needs your permission" in a sentence would have claimed an
      // open prompt on the strength of its own prose.
      waiting: spec == null || status != AgentActivityStatus.awaitingApproval
          ? AgentWaitKind.unrecorded
          : kind.isEmpty
          ? _waitKind(spec, message)
          : declared?.waiting ?? AgentWaitKind.unrecorded,
    );
    if (status != AgentActivityStatus.unknown) reports.record(report);
    return report;
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

  /// The agent's own words in [payload], per [spec]'s candidate paths.
  ///
  /// First non-empty wins. A path that is absent on this event is not a
  /// failure: the paths describe an agent's whole hook surface, and no one
  /// event carries all of them.
  /// Falls back to [AgentHookMeaning.fallbackMessage] when the payload carries
  /// no prose of its own.
  ///
  /// Antigravity's hooks are the case: the event *name* is the whole message —
  /// `Execution failed`, `Maximum token budget exceeded` — and there is no
  /// field to read one out of. A wording the app supplies for an event whose
  /// meaning it declared is not an invented description; it is the description,
  /// and without it those events reach the user as a session name alone.
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
  /// running, per [spec]'s [AgentHookSpec.inFlightPath].
  ///
  /// Only a **non-empty list** counts. A missing key, an empty list and a value
  /// of any other shape all mean "nothing said so", which leaves the event
  /// meaning what its name means — the answer an agent that never sends the
  /// field has to get.
  static bool _inFlight(AgentHookSpec? spec, String event, Object? payload) {
    final path = spec?.inFlightPath[event];
    if (path == null || path.isEmpty) return false;
    final value = _valueAt(path, payload);
    return value is List && value.isNotEmpty;
  }

  /// The hook body as JSON, or `null` when it is not JSON at all.
  ///
  /// A body we cannot read means "the agent did not tell us" for every field at
  /// once, which is what every reader below already renders as nothing.
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

  /// The string at [path] in the decoded [payload], or `''`.
  ///
  /// Empty for a missing key, a non-string value or an unparseable body — all
  /// of which mean "the agent did not tell us", which the caller renders as
  /// nothing rather than as a placeholder.
  /// A **list of one string** reads as that string.
  ///
  /// Antigravity sends the working directory as `workspacePaths`, a JSON array,
  /// and there is no index to name in the path because the CLI sends one entry
  /// — a session has one workspace. Without this, `cwdPath` reads nothing and
  /// adoption falls back to the oldest pane, which is the wrong pane whenever
  /// more than one is open.
  ///
  /// Narrow on purpose: only when the path's own destination is a list whose
  /// first element is a string. A path that names an index (`['a', '0']`)
  /// still resolves through [_valueAt] as it always did, and every string-valued
  /// key — Claude Code's `message` and `last_assistant_message` among them — is
  /// untouched.
  static String _stringAt(List<String> path, Object? payload) {
    final value = _valueAt(path, payload);
    if (value is String) return value;
    if (value is List && value.isNotEmpty && value.first is String) {
      return value.first as String;
    }
    return '';
  }
}
