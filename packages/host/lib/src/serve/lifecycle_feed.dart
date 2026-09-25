import 'dart:async';

import '../domain/host_session.dart';
import '../domain/registry_change.dart';
import '../domain/session_lifecycle.dart';
import '../domain/session_registry.dart';
import '../hooks/hook_holds.dart';
import '../hooks/recent_hooks.dart';
import '../protocol/messages.dart';

/// The host as the recorder of each session's lifecycle: started, exited with
/// the code it collected or none, closed on request — and the relay of every
/// agent hook it takes. Any connection can watch.
class LifecycleFeed {
  LifecycleFeed(
    this._registry, {
    required DateTime Function() clock,
    RecentHooks? hooks,
    HookHolds? holds,
  }) : _now = clock,
       hooks = hooks ?? RecentHooks(),
       holds = holds ?? HookHolds() {
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
  final RecentHooks hooks;
  final HookHolds holds;
  final DateTime Function() _now;
  final _events = StreamController<LifecycleEvent>.broadcast(sync: true);

  /// What a watcher is sent after its snapshot: lifecycle events and hooks, in
  /// the one order they happened. The last watcher hanging up releases every
  /// hold: nobody is left to reply.
  late final _out = StreamController<HostMessage>.broadcast(
    sync: true,
    onCancel: holds.releaseAll,
  );
  final _closed = <String, HostSessionFacts>{};

  /// Keyed by the session object, so a reopened id is a new session and a
  /// pruned one is not kept alive by this map.
  final _exitReported = Expando<bool>();

  Stream<LifecycleEvent> get events => _events.stream;

  /// Whether any connection is watching; a hung-up one is not.
  bool get hasWatchers => _out.hasListener;

  /// Every session this host knows, running, ended or recently closed.
  List<HostSessionFacts> snapshot() => [
    for (final session in _registry.sessions) _factsOf(session),
    for (final facts in _closed.values)
      if (_registry.find(facts.sessionId) == null) facts,
  ];

  /// Called once a watcher is subscribed, with the sessions it runs itself;
  /// what it writes reaches that watcher too.
  void Function(Set<String> runByClient)? onWatched;

  /// Sends the snapshot, then every event and hook, through [send]; cancel to
  /// stop. Subscribed in the same turn the snapshot is taken, so nothing falls
  /// between the two.
  StreamSubscription<HostMessage> watch(
    int requestId,
    void Function(HostMessage) send, {
    Iterable<String> runByClient = const [],
  }) {
    send(
      WatchingMessage(
        requestId: requestId,
        observedAt: _now(),
        sessions: snapshot(),
        hooks: hooks.latest(),
      ),
    );
    final subscription = _out.stream.listen(send);
    onWatched?.call(runByClient.toSet());
    return subscription;
  }

  /// Tells every watcher the daemon wrote automation, run, check, resume or
  /// verification rows.
  void publishAutomationsChanged() =>
      _out.add(const AutomationsChangedMessage());

  /// Tells every watcher the daemon wrote [status] to the row [sessionId].
  void publishSessionChanged(String sessionId, String status) =>
      _out.add(SessionChangedMessage(sessionId: sessionId, status: status));

  /// Keeps [hook] for the snapshot and relays it to every watcher. Completes
  /// when the agent may be answered: at once, unless [hook] is a kind that is
  /// held and someone is watching — then on the first watcher's
  /// [HookReplyMessage], or at [HookHolds.bound]. With nobody watching there is
  /// nobody to wait for; the hook then reaches the app, unheld, in a snapshot.
  Future<void> relayHook(AgentHookEvent hook) {
    hooks.record(hook);
    if (!hasWatchers || !holds.wants(hook)) {
      _out.add(HookMessage(hook));
      return Future<void>.value();
    }
    final hold = holds.open();
    _out.add(HookMessage(hook.heldAs(hold.id)));
    return hold.released;
  }

  /// A watcher is done with the hold [holdId]; false when it was over already.
  bool replyHook(int holdId) => holds.release(holdId);

  /// Watchers get the event before any row change it causes.
  void _emit(LifecycleEvent event) {
    _out.add(LifecycleMessage(event));
    _events.add(event);
  }

  void _onChange(RegistryChange change) {
    switch (change) {
      case SessionOpened(:final session):
        _closed.remove(session.id);
        _emit(
          LifecycleEvent(
            sessionId: session.id,
            kind: LifecycleEventKind.started,
            observedAt: _now(),
            pid: session.pid,
          ),
        );
        _watchExit(session);
      case SessionClosed(:final session, :final end, :final endedByClose):
        // The close can resume before the exit's own callback does; the exit
        // is still told first, and only once.
        _reportExit(session);
        final facts = HostSessionFacts(
          sessionId: session.id,
          state: HostSessionState.closed,
          exitCode: end.exitCode,
          // A leftover let go keeps the reason it ended with.
          reason: endedByClose ? closedReason : reasonOf(end),
          startedAt: session.startedAt,
          endedAt: end.endedAt,
          endedByClose: endedByClose,
        );
        _closed.remove(session.id);
        _closed[session.id] = facts;
        if (_closed.length > keepClosed) _closed.remove(_closed.keys.first);
        _emit(
          LifecycleEvent(
            sessionId: session.id,
            kind: LifecycleEventKind.closed,
            observedAt: _now(),
            exitCode: end.exitCode,
            reason: endedByClose ? closedReason : reasonOf(end),
            endedByClose: endedByClose,
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
    _emit(
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
