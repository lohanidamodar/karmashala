import 'dart:async';

import 'package:karmashala_session/session.dart';

import '../domain/lifecycle_status.dart';
import '../domain/session_facts.dart';
import '../domain/session_reads.dart';

/// One status the recorder wrote.
class SessionLifecycleChange {
  const SessionLifecycleChange({
    required this.sessionId,
    required this.from,
    required this.to,
    this.facts,
  });

  final String sessionId;
  final SessionStatus from;
  final SessionStatus to;

  /// What the host said; null when no host knows the session.
  final SessionFacts? facts;

  @override
  String toString() =>
      'SessionLifecycleChange($sessionId, ${from.name} -> ${to.name})';
}

/// Applies host facts to session rows: the only writer of lifecycle status for
/// a hosted session.
///
/// Precedence, so a status is never replaced by a less-informed one:
/// - an archived row, or one that does not exist, is never touched;
/// - a fact observed before the last one applied for that host session is
///   stale and ignored;
/// - `running` is already said by `running` or `idle` (idle is the
///   conversation's word for a live process);
/// - `unknown` never replaces an ending: an exit nobody saw does not undo
///   `completed`, `failed` or `cancelled`;
/// - `cancelled` is kept against a later exit: the request is why it ended;
/// - otherwise, and always for `running`, the fact wins.
class SessionLifecycleRecorder {
  SessionLifecycleRecorder(this._sessions);

  final SessionStatusStore _sessions;
  final Map<String, DateTime> _lastObserved = {};
  final StreamController<SessionLifecycleChange> _changes =
      StreamController.broadcast(sync: true);

  /// Every status written, as it is written.
  Stream<SessionLifecycleChange> get changes => _changes.stream;

  /// Records [facts] against the row [sessionIdOf] names. Returns what changed,
  /// or null when nothing was written.
  SessionLifecycleChange? apply(
    SessionFacts facts, {
    required String? Function(String hostSessionId) sessionIdOf,
  }) {
    final sessionId = sessionIdOf(facts.hostSessionId);
    if (sessionId == null) return null;
    final last = _lastObserved[facts.hostSessionId];
    if (last != null && facts.observedAt.isBefore(last)) return null;
    final row = _sessions.getById(sessionId);
    if (row == null) return null;
    _lastObserved[facts.hostSessionId] = facts.observedAt;
    return _record(row, lifecycleStatusFrom(facts), facts);
  }

  /// Records a lifecycle event; see [apply].
  SessionLifecycleChange? applyEvent(
    SessionLifecycleEvent event, {
    required String? Function(String hostSessionId) sessionIdOf,
  }) => apply(event.facts, sessionIdOf: sessionIdOf);

  /// Records a host's watch snapshot. Says nothing about sessions it omits:
  /// another host may run them.
  List<SessionLifecycleChange> applySnapshot(
    Iterable<SessionFacts> snapshot, {
    required String? Function(String hostSessionId) sessionIdOf,
  }) => [for (final facts in snapshot) ?apply(facts, sessionIdOf: sessionIdOf)];

  /// Records that no host knows [sessionId]: a row still claiming to run is
  /// now `unknown`; an ending stays.
  SessionLifecycleChange? recordUnseen(String sessionId) {
    final row = _sessions.getById(sessionId);
    return row == null ? null : _record(row, lifecycleStatusFrom(null), null);
  }

  Future<void> dispose() => _changes.close();

  SessionLifecycleChange? _record(
    Session row,
    SessionStatus derived,
    SessionFacts? facts,
  ) {
    if (row.isArchived) return null;
    final current = row.status;
    if (!_replaces(derived, current)) return null;
    _sessions.updateStatus(row.id, derived);
    final change = SessionLifecycleChange(
      sessionId: row.id,
      from: current,
      to: derived,
      facts: facts,
    );
    _changes.add(change);
    return change;
  }

  static bool _replaces(SessionStatus derived, SessionStatus current) {
    if (derived == current) return false;
    if (derived == SessionStatus.running) return !current.claimsLive;
    if (current == SessionStatus.cancelled) return false;
    if (derived == SessionStatus.unknown) return !current.isEnded;
    return true;
  }
}
