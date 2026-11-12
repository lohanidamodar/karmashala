import 'dart:async';

import 'package:agent_cli/descriptors.dart'
    show AgentActivityStatus, AgentSessionEnding, AgentStatusReport;
import 'package:karmashala_session/launch.dart' show SessionSurface;
import 'package:karmashala_session/session.dart';
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
       _rows = store.SessionDao(database),
       _now = clock,
       _onWritten = onWritten;

  final LifecycleFeed _feed;
  final store.SessionDao _rows;
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
    // A row its hooks said runs since this server started is theirs to end:
    // no host was ever going to hold it.
    _feed.onWatched = (runByClient) => _keeper.markUnheld(
      heldHostSessionIds: {for (final f in _feed.snapshot()) f.sessionId},
      runByClient: runByClient,
      keptByHooks: _keptByHooks,
    );
  }

  /// External-surface rows a hook has said run, this server's life.
  final Set<String> _keptByHooks = {};

  /// What an agent's own hook said of a row in a terminal window nobody here
  /// sees (the external surface): working or idle is `running`, its session's
  /// end is the ending. A row the host holds moves only by the host.
  void hookReported(String? paneSessionId, AgentStatusReport report) {
    final row = _externalRowOf(paneSessionId, report.sessionId);
    if (row == null) return;
    final hostId = engine.hostSessionIdOf(row.id);
    if (_feed.snapshot().any((f) => f.sessionId == hostId)) return;
    final status = switch (report.ending) {
      AgentSessionEnding.completed => SessionStatus.completed,
      AgentSessionEnding.failed => SessionStatus.failed,
      AgentSessionEnding.conversationOnly || null => switch (report.status) {
        AgentActivityStatus.working ||
        AgentActivityStatus.idle ||
        AgentActivityStatus.awaitingApproval => SessionStatus.running,
        _ => null,
      },
    };
    if (status == null) return;
    if (status == SessionStatus.running) {
      _keptByHooks.add(row.id);
    } else {
      _keptByHooks.remove(row.id);
    }
    _keeper.recordReported(row.id, status);
  }

  Session? _externalRowOf(String? paneSessionId, String conversationId) {
    final named = paneSessionId == null ? null : _rows.getById(paneSessionId);
    final row =
        named ??
        (conversationId.isEmpty
            ? null
            : _rows.getByExternalSessionId(conversationId));
    return row != null && row.surface == SessionSurface.external ? row : null;
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
