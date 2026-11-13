import 'dart:async';

import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_session/session.dart';

import '../sessions/session_modes.dart';

/// **Moving a session this server runs onto another model**, for a phone's
/// `session.configure` and a desktop's `sessions.setModel` alike. The row is
/// written first; then the agent's model command is typed while it is idle
/// at its prompt, held while it is in a turn that will end, and otherwise
/// left to the next launch. Never typed into a running turn or an open prompt.
class SessionModelSwitcher implements SessionModelChanger {
  SessionModelSwitcher({
    required this.rowOf,
    required this.record,
    required this.agentOf,
    required this.defaultModelOf,
    required this.runningHere,
    required this.statusOf,
    required this.type,
    Stream<String> becameIdle = const Stream.empty(),
    this.notice,
  }) {
    _idle = becameIdle.listen(_turnEnded);
  }

  final Session? Function(String sessionId) rowOf;

  /// Writes the row's model, and tells every client it moved.
  final void Function(String sessionId, String? modelId) record;
  final AgentDescriptor? Function(Session row) agentOf;

  /// What "follow the default" names for [row]'s agent today, or null.
  final String? Function(Session row) defaultModelOf;
  final bool Function(String sessionId) runningHere;
  final AgentActivityStatus? Function(String sessionId) statusOf;

  /// Types [line] into the session and presses Enter; throws when it cannot.
  final Future<void> Function(String sessionId, String line) type;

  /// Told when a held switch was typed after the turn it waited for.
  final void Function(String sessionId, String message)? notice;

  late final StreamSubscription<String> _idle;
  final Set<String> _held = {};

  /// Whether [sessionId] has a switch waiting for its turn to end.
  bool holds(String sessionId) => _held.contains(sessionId);

  @override
  Future<SessionModelSet> setModel(String sessionId, String? modelId) async {
    final row = rowOf(sessionId);
    if (row == null) {
      throw const DataRefused.notFound('this session no longer exists');
    }
    record(sessionId, modelId);
    // A later pick replaces a held one: only the row as it stands is sent.
    _held.remove(sessionId);
    return _switch(sessionId, holdIfBusy: true);
  }

  Future<SessionModelSet> _switch(
    String sessionId, {
    required bool holdIfBusy,
  }) async {
    const recorded = SessionModelSet(outcome: SessionModelOutcome.recorded);
    final row = rowOf(sessionId);
    if (row == null || !runningHere(sessionId)) return recorded;
    final support = agentOf(row)?.launch.model;
    final target = row.modelId ?? defaultModelOf(row);
    if (support == null || target == null) return recorded;
    final String line;
    final SessionModelOutcome done;
    if (support.switchesLive) {
      final command = support.commandFor(target);
      if (command == null) return recorded;
      line = command;
      done = SessionModelOutcome.now;
    } else if (support.pickerCommand.isNotEmpty) {
      // A picker is the person's to answer; it is never held for later.
      if (statusOf(sessionId) != AgentActivityStatus.idle) return recorded;
      line = support.pickerCommand;
      done = SessionModelOutcome.pickerOpened;
    } else {
      return recorded;
    }
    switch (statusOf(sessionId)) {
      case AgentActivityStatus.idle:
        break;
      case AgentActivityStatus.working || AgentActivityStatus.awaitingApproval
          when holdIfBusy:
        _held.add(sessionId);
        return const SessionModelSet(outcome: SessionModelOutcome.afterTurn);
      default:
        // Unknown may never report idle, so a switch held for it could wait
        // for ever: the next launch applies it.
        return recorded;
    }
    try {
      await type(sessionId, line);
    } on Object {
      return recorded;
    }
    return SessionModelSet(outcome: done, line: line);
  }

  Future<void> _turnEnded(String sessionId) async {
    if (!_held.remove(sessionId)) return;
    final answer = await _switch(sessionId, holdIfBusy: false);
    if (answer.outcome != SessionModelOutcome.now) return;
    notice?.call(
      sessionId,
      'The turn ended — switched now: "${answer.line}" was sent to the '
      'session.',
    );
  }

  void dispose() => unawaited(_idle.cancel());
}
