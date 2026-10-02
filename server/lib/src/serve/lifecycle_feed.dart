import 'dart:async';

import '../domain/hosted_process.dart';
import '../domain/registry_change.dart';
import 'package:karmashala_host_protocol/protocol.dart';
import '../domain/session_registry.dart';
import '../hooks/recent_hooks.dart';

/// The host as the recorder of each session's lifecycle: started, exited with
/// the code it collected or none, closed on request — and the relay of every
/// agent hook it takes. Any connection can watch. A PTY and an ACP agent are
/// recorded alike: both are processes the registry holds under a session id.
class LifecycleFeed {
  LifecycleFeed(
    this._registry, {
    required DateTime Function() clock,
    RecentHooks? hooks,
  }) : _now = clock,
       hooks = hooks ?? RecentHooks() {
    for (final process in _registry.processes) {
      _watchExit(process);
    }
    _registry.changes.listen(_onChange);
  }

  static const closedReason = 'closed on request';

  /// Closed sessions leave the registry; the snapshot remembers this many, so
  /// a watcher that reconnects still learns they were closed.
  static const keepClosed = 64;

  final SessionRegistry _registry;
  final RecentHooks hooks;
  final DateTime Function() _now;
  final _events = StreamController<LifecycleEvent>.broadcast(sync: true);

  /// What a watcher is sent after its snapshot: lifecycle events and hooks, in
  /// the one order they happened.
  final _out = StreamController<HostMessage>.broadcast(sync: true);
  final _closed = <String, HostSessionFacts>{};

  /// Keyed by the process object, so a reopened id is a new session and a
  /// pruned one is not kept alive by this map.
  final _exitReported = Expando<bool>();

  Stream<LifecycleEvent> get events => _events.stream;

  /// Whether any connection is watching; a hung-up one is not.
  bool get hasWatchers => _out.hasListener;

  /// Every session this host knows, running, ended or recently closed.
  List<HostSessionFacts> snapshot() => [
    for (final process in _registry.processes) _factsOf(process),
    for (final facts in _closed.values)
      if (_registry.findProcess(facts.sessionId) == null) facts,
  ];

  /// Called once a watcher is subscribed, with the sessions it runs itself;
  /// what it writes reaches that watcher too.
  void Function(Set<String> runByClient)? onWatched;

  /// What the agent in each hosted session is doing, for a watcher's snapshot
  /// (`HostedAgentStatus.toJson` each); null while no status is kept.
  List<Map<String, Object?>> Function()? statusSnapshot;

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
        statuses: statusSnapshot?.call() ?? const [],
      ),
    );
    final subscription = _out.stream.listen(send);
    onWatched?.call(runByClient.toSet());
    return subscription;
  }

  /// Tells every watcher what the agent in the row [sessionId] is doing now,
  /// or — [status] null — that it is no longer kept.
  void publishAgentStatus(String sessionId, Map<String, Object?>? status) =>
      _out.add(AgentStatusMessage(sessionId: sessionId, status: status));

  /// Keeps [hook] for the snapshot and relays it to every watcher. Nothing
  /// waits on a watcher: a tool the hook announces is held, when it is, by
  /// the server's own checkpoint recorder before this is called.
  void relayHook(AgentHookEvent hook) {
    hooks.record(hook);
    _out.add(HookMessage(hook));
  }

  /// Watchers get the event before any row change it causes.
  void _emit(LifecycleEvent event) {
    _out.add(LifecycleMessage(event));
    _events.add(event);
  }

  void _onChange(RegistryChange change) {
    switch (change) {
      case SessionOpened(:final process):
        _closed.remove(process.id);
        _emit(
          LifecycleEvent(
            sessionId: process.id,
            kind: LifecycleEventKind.started,
            observedAt: _now(),
            pid: process.pid,
          ),
        );
        _watchExit(process);
      case SessionClosed(:final process, :final end, :final endedByClose):
        // The close can resume before the exit's own callback does; the exit
        // is still told first, and only once.
        _reportExit(process);
        final facts = HostSessionFacts(
          sessionId: process.id,
          state: HostSessionState.closed,
          exitCode: end.exitCode,
          // A leftover let go keeps the reason it ended with.
          reason: endedByClose ? closedReason : reasonOf(end),
          startedAt: process.startedAt,
          endedAt: end.endedAt,
          endedByClose: endedByClose,
        );
        _closed.remove(process.id);
        _closed[process.id] = facts;
        if (_closed.length > keepClosed) _closed.remove(_closed.keys.first);
        _emit(
          LifecycleEvent(
            sessionId: process.id,
            kind: LifecycleEventKind.closed,
            observedAt: _now(),
            exitCode: end.exitCode,
            reason: endedByClose ? closedReason : reasonOf(end),
            endedByClose: endedByClose,
          ),
        );
    }
  }

  void _watchExit(HostedProcess process) {
    if (process.lifecycle.hasEnded) {
      // Read back from a record: its end belongs to the last host's feed.
      _exitReported[process] = true;
      return;
    }
    unawaited(process.ended.then((_) => _reportExit(process)));
  }

  void _reportExit(HostedProcess process) {
    if (_exitReported[process] == true) return;
    _exitReported[process] = true;
    final end = process.lifecycle;
    // The exit a close caused says so, or a watcher reads the signal's code
    // as the program failing before the `closed` that follows corrects it.
    _emit(
      LifecycleEvent(
        sessionId: process.id,
        kind: LifecycleEventKind.exited,
        observedAt: _now(),
        exitCode: end.exitCode,
        reason: reasonOf(end),
        endedByClose: process.closeRequested,
      ),
    );
  }

  static HostSessionFacts _factsOf(HostedProcess process) {
    final lifecycle = process.lifecycle;
    return HostSessionFacts(
      sessionId: process.id,
      state: lifecycle.hasEnded
          ? HostSessionState.exited
          : HostSessionState.running,
      exitCode: lifecycle.exitCode,
      reason: reasonOf(lifecycle),
      startedAt: process.startedAt,
      endedAt: lifecycle.endedAt,
      // Ended by a close still finishing: the row says so before `closed`.
      endedByClose: lifecycle.hasEnded && process.closeRequested,
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
