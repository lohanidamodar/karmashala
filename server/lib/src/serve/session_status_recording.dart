import 'dart:async';

import 'package:karmashala_session_engine/karmashala_session_engine.dart'
    as engine;
import 'package:karmashala_session_engine/store.dart' as store;
import 'package:karmashala_store/database.dart';

import 'package:karmashala_host_protocol/protocol.dart';
import 'lifecycle_feed.dart';

/// The daemon writing its own sessions' lifecycle status to the shared store:
/// the snapshot at start, each event after it, and — each time a client
/// watches — the rows it does not hold. Every row written is handed to
/// [onWritten] — the data service, which tells every client of it on the
/// data channel.
///
/// [resolveUnknown] says what a host's silence means for the rows whose
/// agent this server runs outright (an agent spoken to over a protocol —
/// `sessionEndsWithServer`): an end, clean or failed by its reason, never
/// `unknown`, since there is no process of it anywhere to lose sight of.
class SessionStatusRecording {
  SessionStatusRecording(
    this._feed,
    AppDatabase database, {
    required DateTime Function() clock,
    void Function(String sessionId)? onWritten,
    engine.UnknownResolver? resolveUnknown,
  }) : _keeper = store.keeperOver(database, resolveUnknown: resolveUnknown),
       _now = clock,
       _onWritten = onWritten;

  final LifecycleFeed _feed;
  final void Function(String sessionId)? _onWritten;
  final engine.HostedSessionStatusKeeper _keeper;
  final DateTime Function() _now;

  /// Every status written; synchronous, inside the write.
  Stream<engine.SessionLifecycleChange> get changes => _keeper.changes;
  final _subscriptions = <StreamSubscription<Object?>>[];

  void start() {
    _subscriptions
      ..add(
        _keeper.changes.listen((change) => _onWritten?.call(change.sessionId)),
      )
      ..add(_feed.events.listen((e) => _keeper.applyEvent(eventOf(e))));
    final observedAt = _now();
    _keeper.applySnapshot([
      for (final facts in _feed.snapshot()) factsOf(facts, observedAt),
    ]);
    // Every local terminal runs in this server (slice 5a), so a row on this
    // machine still claiming to run what it does not hold is a leftover of a
    // server that has gone, whether or not a client ever watches.
    _keeper.markUnheld(
      heldHostSessionIds: {for (final f in _feed.snapshot()) f.sessionId},
    );
    _feed.onWatched = (runByClient) => _keeper.markUnheld(
      heldHostSessionIds: {for (final f in _feed.snapshot()) f.sessionId},
      runByClient: runByClient,
    );
  }

  /// Records [event] from an SSH box's host (slice 5d): a session there that
  /// runs a row's agent starts and exits as the box says — its facts, never
  /// a guess made here.
  void applyRemote(LifecycleEvent event) => _keeper.applyEvent(eventOf(event));

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
