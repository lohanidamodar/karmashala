import 'dart:async';
import 'dart:convert';

import 'package:agent_cli/descriptors.dart' show AgentActivityStatus;
import 'package:karmashala_agent_status/karmashala_agent_status.dart'
    show HostedAgentStatus;
import 'package:karmashala_host_protocol/protocol.dart'
    show LifecycleEvent, LifecycleEventKind, SessionEndedWithoutCode;
import 'package:karmashala_session/lineage.dart' show SessionLink;
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart'
    show sessionIdForHostId;

/// The app-metadata key holding the turns left open: one small JSON map, so
/// no table outlives the few rows it ever holds.
const String kOpenTurnsKey = 'open_turns.v1';

/// The `settings.v1` key that turns the automatic continue off; absent is on.
const String kContinueInterruptedTurnsSetting = 'continueInterruptedTurns';

/// What a session whose turn was cut off is told when it is resumed.
const String kInterruptedTurnPrompt =
    'Karmashala restarted while your last turn was running, so that turn was '
    'cut off before it finished. Check where the work stands and continue '
    'from there.';

/// How old a cut-off turn may be and still be continued unasked — the same
/// distance the app's quit-and-reopen keeps.
const Duration kInterruptedTurnFreshness = Duration(hours: 12);

/// Automatic continues in a row, none of them settling, after which a session
/// is left for a person: the guard against a crash loop.
const int kMaxAutomaticContinues = 3;

/// Whether `settings.v1` ([raw]) lets the server continue interrupted turns.
bool continuesInterruptedTurns(String? raw) {
  try {
    final decoded = raw == null ? null : jsonDecode(raw);
    if (decoded is Map) {
      return decoded[kContinueInterruptedTurnsSetting] != false;
    }
  } on FormatException {
    // Defaults.
  }
  return true;
}

/// A turn recorded as running: when it began, how many automatic continues
/// in a row led to it, and whether a `subagent_run` call was waiting on it.
class OpenTurn {
  const OpenTurn({
    required this.since,
    this.continues = 0,
    this.byCall = false,
  });

  final DateTime since;
  final int continues;
  final bool byCall;

  OpenTurn withByCall(bool byCall) =>
      OpenTurn(since: since, continues: continues, byCall: byCall);

  Map<String, Object?> toJson() => {
    'since': since.toUtc().toIso8601String(),
    if (continues > 0) 'continues': continues,
    if (byCall) 'byCall': true,
  };

  static OpenTurn? fromJson(Object? json) {
    if (json is! Map) return null;
    final since = DateTime.tryParse('${json['since']}');
    if (since == null) return null;
    final continues = json['continues'];
    return OpenTurn(
      since: since.toUtc(),
      continues: continues is int && continues > 0 ? continues : 0,
      byCall: json['byCall'] == true,
    );
  }
}

/// **Which sessions this server runs are mid-turn**, written through on every
/// edge so a crash leaves the record behind. A turn opens when its agent
/// starts working or asks for approval, and closes when it settles or its
/// session ends any way but with the server.
class OpenTurns {
  OpenTurns({
    required String? Function() read,
    required void Function(String value) write,
  }) : _write = write,
       _open = _decode(read());

  final void Function(String value) _write;
  final Map<String, OpenTurn> _open;
  final Map<String, int> _continuing = {};
  final Set<String> _byCall = {};

  Map<String, OpenTurn> get open => Map.unmodifiable(_open);

  /// Row [sessionId]'s agent moved to [status] at [at].
  void statusMoved(String sessionId, AgentActivityStatus status, DateTime at) {
    switch (status) {
      case AgentActivityStatus.working || AgentActivityStatus.awaitingApproval:
        if (_open.containsKey(sessionId)) return;
        _open[sessionId] = OpenTurn(
          since: at.toUtc(),
          continues: _continuing.remove(sessionId) ?? 0,
          byCall: _byCall.contains(sessionId),
        );
        _save();
      case AgentActivityStatus.idle || AgentActivityStatus.failed:
        if (_open.remove(sessionId) != null) _save();
      case AgentActivityStatus.unknown:
        // Losing sight of a turn is not its end.
        return;
    }
  }

  /// Row [sessionId]'s turn settled by the server's own decision
  /// (`TurnSettlement`): a reader that never says idle over a quiet screen.
  void settled(String sessionId) {
    if (_open.remove(sessionId) != null) _save();
  }

  /// The host session [hostSessionId] ended for [reason]. The server's own
  /// stop keeps the turn open: that is the cut-off this record is for.
  void ended(String hostSessionId, {String? reason}) {
    if (reason == SessionEndedWithoutCode.hostStopped ||
        reason == SessionEndedWithoutCode.hostStoppedWhileRunning) {
      return;
    }
    final sessionId = sessionIdForHostId(hostSessionId, _open.keys);
    if (sessionId != null && _open.remove(sessionId) != null) _save();
  }

  /// Row [sessionId] is ([held]) or no longer is waited on by a
  /// `subagent_run` call, whose parent owns what becomes of its turn.
  void heldByCall(String sessionId, bool held) {
    if (held) {
      _byCall.add(sessionId);
    } else {
      _byCall.remove(sessionId);
    }
    final turn = _open[sessionId];
    if (turn == null || turn.byCall == held) return;
    _open[sessionId] = turn.withByCall(held);
    _save();
  }

  /// The next turn row [sessionId] opens is the [continues]th automatic
  /// continue in a row.
  void continuing(String sessionId, int continues) =>
      _continuing[sessionId] = continues;

  /// Every open turn, cleared from the record before anything acts on it, so
  /// a server that dies resuming them does not resume them again.
  Map<String, OpenTurn> takeAll() {
    final taken = Map<String, OpenTurn>.of(_open);
    if (taken.isEmpty) return taken;
    _open.clear();
    _save();
    return taken;
  }

  void _save() => _write(
    jsonEncode({
      for (final entry in _open.entries) entry.key: entry.value.toJson(),
    }),
  );

  static Map<String, OpenTurn> _decode(String? raw) {
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return {
        for (final entry in decoded.entries)
          if (entry.key is String)
            entry.key as String: ?OpenTurn.fromJson(entry.value),
      };
    } on FormatException {
      return {};
    }
  }
}

/// Keeps [turns] in step with the statuses of the agents this server runs
/// itself ([runsHere]: a box's session runs on without it) and with every
/// session end, and closes a turn the server decides has [settled] (a quiet
/// screen its reader cannot read). Cancel these before the server's stop ends
/// its sessions.
List<StreamSubscription<Object?>> followOpenTurns(
  OpenTurns turns, {
  required Stream<HostedAgentStatus> statuses,
  required Stream<LifecycleEvent> lifecycle,
  required bool Function(String sessionId) runsHere,
  required DateTime Function() clock,
  Stream<String>? settled,
}) => [
  statuses.listen((status) {
    if (!runsHere(status.sessionId)) return;
    turns.statusMoved(status.sessionId, status.report.turnStatus, clock());
  }),
  lifecycle.listen((event) {
    if (event.kind == LifecycleEventKind.started) return;
    turns.ended(event.sessionId, reason: event.reason);
  }),
  ?settled?.listen((sessionId) {
    if (runsHere(sessionId)) turns.settled(sessionId);
  }),
];

/// One cut-off turn, why it is not continued, and whether a person should
/// hear of it: a row they stopped, archived or handed on is their own doing.
typedef InterruptedTurnSkip = ({
  String sessionId,
  String reason,
  bool forAPerson,
});

/// What a boot does with the turns it found open.
typedef InterruptedTurnPlan = ({
  List<({String sessionId, OpenTurn turn})> resume,
  List<InterruptedTurnSkip> skipped,
});

/// Which of [open] to continue. A session a person ended, archived or handed
/// on is left alone, as is one already running or too old to continue unasked.
InterruptedTurnPlan planInterruptedTurns(
  Map<String, OpenTurn> open, {
  required Session? Function(String sessionId) sessionOf,
  required List<Session> Function(String sessionId) childrenOf,
  required bool Function(String sessionId) runsHere,
  required DateTime now,
}) {
  final resume = <({String sessionId, OpenTurn turn})>[];
  final skipped = <InterruptedTurnSkip>[];
  for (final MapEntry(key: id, value: turn) in open.entries) {
    final reason = _refusal(
      sessionOf(id),
      turn,
      childrenOf: childrenOf,
      runsHere: runsHere,
      now: now,
    );
    if (reason == null) {
      resume.add((sessionId: id, turn: turn));
    } else {
      skipped.add((
        sessionId: id,
        reason: reason.text,
        forAPerson: reason.forAPerson,
      ));
    }
  }
  return (resume: resume, skipped: skipped);
}

({String text, bool forAPerson})? _refusal(
  Session? session,
  OpenTurn turn, {
  required List<Session> Function(String sessionId) childrenOf,
  required bool Function(String sessionId) runsHere,
  required DateTime now,
}) {
  ({String text, bool forAPerson}) own(String text) =>
      (text: text, forAPerson: false);
  if (session == null) return own('it is no longer in the workspace');
  if (session.isArchived) return own('it was archived');
  if (turn.byCall) {
    return own("its parent's subagent_run call was waiting on it");
  }
  // A row the server's stop left is `unknown`, or `completed` for an agent
  // that runs inside the server; these two only ever come from elsewhere.
  if (session.status == SessionStatus.cancelled) return own('it was stopped');
  if (session.status == SessionStatus.failed) return own('it ended in error');
  if (childrenOf(
    session.id,
  ).any((child) => child.parentLink == SessionLink.handoff)) {
    return own('its work was handed off');
  }
  if (runsHere(session.id)) return own('it is already running');
  final reason = _staleness(session, turn, now);
  return reason == null ? null : (text: reason, forAPerson: true);
}

String? _staleness(Session session, OpenTurn turn, DateTime now) {
  final conversation = session.externalSessionId;
  if (conversation == null || conversation.isEmpty) {
    return 'its agent never named a conversation to resume';
  }
  if (now.difference(turn.since) > kInterruptedTurnFreshness) {
    return 'its turn began more than ${kInterruptedTurnFreshness.inHours} '
        'hours ago';
  }
  if (turn.continues >= kMaxAutomaticContinues) {
    return 'it was cut off again after ${turn.continues} automatic continues';
  }
  return null;
}

/// What the inbox says of a turn the session host's stop cut off.
const String kTurnCutOffLead =
    'The session host stopped while this turn was running.';

/// **Turns a server stop or crash cut off, continued at the next boot**
/// without asking (owner, 2026-10-03): each session resumed and told its turn
/// was cut off — on its command line or as its first ACP prompt; an agent
/// that takes no opening message is reopened and the log says it was not
/// told. Once per boot: the record is cleared before any resume starts. Each
/// session continued, or left for a person, is [report]ed for the inbox.
class InterruptedTurnContinuer {
  InterruptedTurnContinuer({
    required this.turns,
    required this.sessionOf,
    required this.childrenOf,
    required this.runsHere,
    required this.takesOpeningMessage,
    required this.resume,
    required this.now,
    this.enabled,
    this.report,
    this.log,
  });

  final OpenTurns turns;
  final Session? Function(String sessionId) sessionOf;
  final List<Session> Function(String sessionId) childrenOf;
  final bool Function(String sessionId) runsHere;

  /// Whether [Session]'s agent can be handed a message as it starts.
  final bool Function(Session session) takesOpeningMessage;
  final Future<void> Function(String sessionId, String? prompt) resume;
  final DateTime Function() now;

  /// Settings; null is on.
  final bool Function()? enabled;

  /// Files what happened to row [String]'s cut-off turn, in plain words.
  final void Function(String sessionId, String detail)? report;
  final void Function(String message)? log;

  bool _ran = false;

  /// Takes the open turns and starts every resume before its first await, so
  /// a client's resume of the same row arrives after and is answered by it.
  /// Returns the rows continued.
  Future<List<String>> run() async {
    if (_ran) return const [];
    _ran = true;
    final open = turns.takeAll();
    if (open.isEmpty) return const [];
    final plan = planInterruptedTurns(
      open,
      sessionOf: sessionOf,
      childrenOf: childrenOf,
      runsHere: runsHere,
      now: now(),
    );
    for (final skip in plan.skipped) {
      log?.call(
        'interrupted turns: ${skip.sessionId} not continued — ${skip.reason}',
      );
      if (skip.forAPerson) _left(skip.sessionId, skip.reason);
    }
    if (!(enabled?.call() ?? true)) {
      log?.call(
        'interrupted turns: ${open.length} cut off by the last stop, not '
        'continued — switched off in Settings',
      );
      for (final (:sessionId, turn: _) in plan.resume) {
        _left(sessionId, 'continuing them is switched off in Settings');
      }
      return const [];
    }
    final continued = <String>[];
    final runs = <Future<void>>[];
    for (final (:sessionId, :turn) in plan.resume) {
      final session = sessionOf(sessionId);
      if (session == null) continue;
      final told = takesOpeningMessage(session);
      turns.continuing(sessionId, turn.continues + 1);
      runs.add(_continue(sessionId, told, continued));
    }
    await Future.wait(runs);
    return continued;
  }

  void _left(String sessionId, String reason) => report?.call(
    sessionId,
    '$kTurnCutOffLead It was not continued: $reason.',
  );

  Future<void> _continue(
    String sessionId,
    bool told,
    List<String> continued,
  ) async {
    try {
      await resume(sessionId, told ? kInterruptedTurnPrompt : null);
      continued.add(sessionId);
      log?.call(
        told
            ? 'interrupted turns: $sessionId resumed and told its turn was '
                  'cut off'
            : 'interrupted turns: $sessionId resumed; its agent takes no '
                  'opening message, so it was not told its turn was cut off',
      );
      report?.call(
        sessionId,
        told
            ? '$kTurnCutOffLead Karmashala continued it and told the agent '
                  'its turn was cut off.'
            : '$kTurnCutOffLead Karmashala reopened the session, but its '
                  'agent takes no opening message, so it was not asked to '
                  'continue.',
      );
    } on Object catch (error) {
      log?.call('interrupted turns: $sessionId could not be resumed: $error');
      _left(sessionId, 'reopening the session failed');
    }
  }
}
