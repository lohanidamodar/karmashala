import 'dart:async';

import '../domain/host_session.dart';
import '../domain/registry_change.dart';
import '../domain/session_lifecycle.dart';
import '../domain/session_registry.dart';
import '../protocol/messages.dart';

/// The host as the recorder of each session's lifecycle: started, exited with
/// the code it collected or none, closed on request. Any connection can watch.
class LifecycleFeed {
  LifecycleFeed(this._registry, {required DateTime Function() clock})
    : _now = clock {
    for (final session in _registry.sessions) {
      _watchExit(session);
    }
    _registry.changes.listen(_onChange);
  }

  static const closedReason = 'closed on request';

  /// Closed sessions leave the registry; the snapshot remembers this many, so
  /// a watcher that reconnects still learns they were closed.
  static const keepClosed = 64;

  final SessionRegistry _registry;
  final DateTime Function() _now;
  final _events = StreamController<LifecycleEvent>.broadcast(sync: true);
  final _closed = <String, HostSessionFacts>{};

  /// Keyed by the session object, so a reopened id is a new session and a
  /// pruned one is not kept alive by this map.
  final _exitReported = Expando<bool>();

  Stream<LifecycleEvent> get events => _events.stream;

  /// Whether any connection is watching; a hung-up one is not.
  bool get hasWatchers => _events.hasListener;

  /// Every session this host knows, running, ended or recently closed.
  List<HostSessionFacts> snapshot() => [
    for (final session in _registry.sessions) _factsOf(session),
    for (final facts in _closed.values)
      if (_registry.find(facts.sessionId) == null) facts,
  ];

  /// Sends the snapshot, then every event, through [send]; cancel to stop.
  /// Subscribed in the same turn the snapshot is taken, so nothing falls
  /// between the two.
  StreamSubscription<LifecycleEvent> watch(
    int requestId,
    void Function(HostMessage) send,
  ) {
    send(
      WatchingMessage(
        requestId: requestId,
        observedAt: _now(),
        sessions: snapshot(),
      ),
    );
    return events.listen((event) => send(LifecycleMessage(event)));
  }

  void _onChange(RegistryChange change) {
    switch (change) {
      case SessionOpened(:final session):
        _closed.remove(session.id);
        _events.add(
          LifecycleEvent(
            sessionId: session.id,
            kind: LifecycleEventKind.started,
            observedAt: _now(),
            pid: session.pid,
          ),
        );
        _watchExit(session);
      case SessionClosed(:final session, :final end):
        // The close can resume before the exit's own callback does; the exit
        // is still told first, and only once.
        _reportExit(session);
        final facts = HostSessionFacts(
          sessionId: session.id,
          state: HostSessionState.closed,
          exitCode: end.exitCode,
          reason: closedReason,
          startedAt: session.startedAt,
          endedAt: end.endedAt,
        );
        _closed.remove(session.id);
        _closed[session.id] = facts;
        if (_closed.length > keepClosed) _closed.remove(_closed.keys.first);
        _events.add(
          LifecycleEvent(
            sessionId: session.id,
            kind: LifecycleEventKind.closed,
            observedAt: _now(),
            exitCode: end.exitCode,
            reason: closedReason,
          ),
        );
    }
  }

  void _watchExit(HostSession session) {
    if (session.lifecycle.hasEnded) {
      // Read back from a record: its end belongs to the last host's feed.
      _exitReported[session] = true;
      return;
    }
    unawaited(session.ended.then((_) => _reportExit(session)));
  }

  void _reportExit(HostSession session) {
    if (_exitReported[session] == true) return;
    _exitReported[session] = true;
    final end = session.lifecycle;
    _events.add(
      LifecycleEvent(
        sessionId: session.id,
        kind: LifecycleEventKind.exited,
        observedAt: _now(),
        exitCode: end.exitCode,
        reason: reasonOf(end),
      ),
    );
  }

  static HostSessionFacts _factsOf(HostSession session) {
    final lifecycle = session.lifecycle;
    return HostSessionFacts(
      sessionId: session.id,
      state: lifecycle.hasEnded
          ? HostSessionState.exited
          : HostSessionState.running,
      exitCode: lifecycle.exitCode,
      reason: reasonOf(lifecycle),
      startedAt: session.startedAt,
      endedAt: lifecycle.endedAt,
    );
  }

  /// `exited` for a collected code — a signal reads as `128 + n` and cannot be
  /// told from a program's own exit — or the reason a code is missing.
  static String? reasonOf(SessionLifecycle lifecycle) => switch (lifecycle) {
    SessionRunning() => null,
    SessionExited() => 'exited',
    SessionEndedWithoutCode(:final reason) => reason,
  };
}
