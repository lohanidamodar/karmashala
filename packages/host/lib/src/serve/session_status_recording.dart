import 'dart:async';

import 'package:karmashala_session_engine/karmashala_session_engine.dart'
    as engine;
import 'package:karmashala_store/database.dart';

import '../protocol/messages.dart';
import 'lifecycle_feed.dart';

/// The daemon writing its own sessions' lifecycle status to the shared store:
/// the snapshot at start, each event after it, and — each time a client
/// watches — the rows it does not hold. Every write is published to watchers
/// as a `sessionChanged`.
class SessionStatusRecording {
  SessionStatusRecording(
    this._feed,
    AppDatabase database, {
    required DateTime Function() clock,
  }) : _keeper = engine.HostedSessionStatusKeeper(database),
       _now = clock;

  final LifecycleFeed _feed;
  final engine.HostedSessionStatusKeeper _keeper;
  final DateTime Function() _now;

  /// Every status written; synchronous, inside the write.
  Stream<engine.SessionLifecycleChange> get changes => _keeper.changes;
  final _subscriptions = <StreamSubscription<Object?>>[];

  void start() {
    _subscriptions
      ..add(
        _keeper.changes.listen(
          (change) =>
              _feed.publishSessionChanged(change.sessionId, change.to.name),
        ),
      )
      ..add(_feed.events.listen((e) => _keeper.applyEvent(eventOf(e))));
    final observedAt = _now();
    _keeper.applySnapshot([
      for (final facts in _feed.snapshot()) factsOf(facts, observedAt),
    ]);
    _feed.onWatched = (runByClient) => _keeper.markUnheld(
      heldHostSessionIds: {for (final f in _feed.snapshot()) f.sessionId},
      runByClient: runByClient,
    );
  }

  Future<void> close() async {
    _feed.onWatched = null;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _keeper.dispose();
  }

  static engine.SessionFacts factsOf(
    HostSessionFacts facts,
    DateTime observedAt,
  ) => engine.SessionFacts(
    hostSessionId: facts.sessionId,
    state: switch (facts.state) {
      HostSessionState.running => engine.HostSessionState.running,
      HostSessionState.exited => engine.HostSessionState.exited,
      HostSessionState.closed => engine.HostSessionState.closed,
    },
    exitCode: facts.exitCode,
    reason: facts.reason,
    endedByClose: facts.endedByClose,
    observedAt: observedAt.toUtc(),
  );

  static engine.SessionLifecycleEvent eventOf(LifecycleEvent event) =>
      engine.SessionLifecycleEvent(
        hostSessionId: event.sessionId,
        kind: switch (event.kind) {
          LifecycleEventKind.started => engine.SessionLifecycleKind.started,
          LifecycleEventKind.exited => engine.SessionLifecycleKind.exited,
          LifecycleEventKind.closed => engine.SessionLifecycleKind.closed,
        },
        exitCode: event.exitCode,
        reason: event.reason,
        endedByClose: event.endedByClose,
        observedAt: event.observedAt.toUtc(),
      );
}
