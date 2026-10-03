import 'dart:async';

import 'package:karmashala_session/session.dart';

import '../domain/lifecycle_status.dart';
import '../domain/session_facts.dart';
import '../domain/session_reads.dart';
import 'session_lifecycle_recorder.dart';

/// The daemon's side of the rows: applies its own host's facts to the rows
/// they name, and marks the rows it does not hold. The only writer of a hosted
/// row's lifecycle status; every write is on [changes]. Over the server's
/// store (`keeperOver` in `store.dart`), or any [SessionStatusStore].
/// [resolveUnknown] says what a host's silence means for a row whose agent
/// the server runs outright — see [SessionLifecycleRecorder].
class HostedSessionStatusKeeper {
  HostedSessionStatusKeeper(
    this._sessions, {
    required bool Function(Session session) runsOnThisMachine,
    UnknownResolver? resolveUnknown,
  }) : _runsHere = runsOnThisMachine,
       _recorder = SessionLifecycleRecorder(
         _sessions,
         resolveUnknown: resolveUnknown,
       );

  final SessionStatusStore _sessions;
  final bool Function(Session session) _runsHere;
  final SessionLifecycleRecorder _recorder;

  Stream<SessionLifecycleChange> get changes => _recorder.changes;

  List<SessionLifecycleChange> applySnapshot(Iterable<SessionFacts> snapshot) =>
      _recorder.applySnapshot(snapshot, sessionIdOf: _sessionIdOf);

  SessionLifecycleChange? applyEvent(SessionLifecycleEvent event) =>
      _recorder.applyEvent(event, sessionIdOf: _sessionIdOf);

  /// Rows on this machine still claiming to run that the host does not hold
  /// ([heldHostSessionIds]) become `unknown` — except [runByClient], sessions a
  /// client runs in its own panes, which no host could know.
  List<SessionLifecycleChange> markUnheld({
    required Set<String> heldHostSessionIds,
    Set<String> runByClient = const {},
  }) => [
    for (final session in _sessions.getClaimingLive())
      if (!session.isArchived &&
          !runByClient.contains(session.id) &&
          !heldHostSessionIds.contains(hostSessionIdOf(session.id)) &&
          _runsHere(session))
        ?_recorder.recordUnseen(session.id),
  ];

  Future<void> dispose() => _recorder.dispose();

  String? _sessionIdOf(String hostSessionId) => sessionIdForHostId(
    hostSessionId,
    _sessions.getAll().where((s) => !s.isArchived).map((s) => s.id),
  );
}
