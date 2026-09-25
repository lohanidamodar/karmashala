import 'dart:async';

import '../pty/pty.dart';
import 'host_session.dart';
import 'output_backlog.dart';
import 'registry_change.dart';
import 'session_lifecycle.dart';
import 'session_recorder.dart';

/// What `list` answers with. Every field was observed; the reading's age is the
/// caller's to compute from [observedAt].
class SessionSummary {
  const SessionSummary({
    required this.id,
    required this.argv,
    required this.workingDirectory,
    required this.pid,
    required this.columns,
    required this.rows,
    required this.startedAt,
    required this.observedAt,
    required this.totalBytes,
    required this.firstAvailableOffset,
    required this.lifecycle,
    required this.writeHolder,
  });

  final String id;
  final List<String> argv;
  final String? workingDirectory;
  final int pid;
  final int columns;
  final int rows;
  final DateTime startedAt;

  /// When the host looked. A summary that travelled over SSH is already old.
  final DateTime observedAt;

  final int totalBytes;
  final int firstAvailableOffset;
  final SessionLifecycle lifecycle;
  final String? writeHolder;
}

class SessionAlreadyExists implements Exception {
  const SessionAlreadyExists(this.id);
  final String id;
  @override
  String toString() => 'session "$id" already exists on this host';
}

class UnknownSession implements Exception {
  const UnknownSession(this.id);
  final String id;
  @override
  String toString() => 'no session "$id" on this host';
}

/// Every session this host owns. Sessions are never removed because a client
/// went away — only when they have ended and somebody asks to forget them.
class SessionRegistry {
  SessionRegistry({
    required PtyLauncher launcher,
    this.store,
    this.backlogCapacityBytes = OutputBacklog.defaultCapacityBytes,
    this.keepEndedSessions = defaultKeepEndedSessions,
    DateTime Function()? clock,
  }) : _launcher = launcher,
       _now = clock ?? DateTime.now {
    _restore();
  }

  /// Not zero, or a pane reconnecting a moment late reads "unknown" instead of
  /// a real exit code; not unbounded, because each holds up to 4 MiB of backlog.
  static const int defaultKeepEndedSessions = 16;

  final PtyLauncher _launcher;

  /// Where sessions are kept beyond this process; null means memory only.
  final SessionBacklogStore? store;

  final int backlogCapacityBytes;
  final int keepEndedSessions;
  final DateTime Function() _now;
  final _sessions = <String, HostSession>{};

  // Synchronous, so a listener sees an opened session before any of its exit.
  final _changes = StreamController<RegistryChange>.broadcast(sync: true);

  /// Sessions opened and closed on request, as they happen.
  Stream<RegistryChange> get changes => _changes.stream;

  Iterable<HostSession> get sessions => _sessions.values;

  HostSession? find(String id) => _sessions[id];

  /// What the previous host left behind, read once at construction. A record
  /// that says *running* comes back ended with no exit code and a reason, never
  /// as a session somebody could type into.
  void _restore() {
    final source = store;
    if (source == null) return;
    for (final persisted in source.restore()) {
      _sessions[persisted.id] = HostSession.restored(
        id: persisted.id,
        request: persisted.request,
        startedAt: persisted.startedAt,
        restoredBacklog: persisted.backlog,
        lifecycle: persisted.lifecycle,
      );
    }
    // The bound applies across restarts too, or sixteen crashes accumulate.
    _pruneEnded();
  }

  HostSession require(String id) {
    final session = _sessions[id];
    if (session == null) throw UnknownSession(id);
    return session;
  }

  /// Opens under an id the client chose, so a pane reattaches to its own
  /// session without the host inventing names.
  HostSession open(String id, PtySpawnRequest request) {
    final existing = _sessions[id];
    if (existing != null) {
      // An ended session under this id is a record, not an owner; refusing
      // would leave the id unusable until somebody closed it explicitly.
      if (!existing.lifecycle.hasEnded) throw SessionAlreadyExists(id);
      _sessions.remove(id);
      existing.recorder?.close();
      store?.forget(id);
    }
    final startedAt = _now();
    // The record first: a spawn that fails after it is undone here, while a
    // child spawned before a record that fails would run on with no owner.
    final recorder = store?.open(id, request, startedAt);
    final PtyHandle pty;
    try {
      pty = _launcher.start(request);
    } on Object {
      recorder?.close();
      store?.forget(id);
      rethrow;
    }
    final session = HostSession(
      id: id,
      request: request,
      pty: pty,
      startedAt: startedAt,
      backlogCapacityBytes: backlogCapacityBytes,
      recorder: recorder,
    );
    _sessions[id] = session;
    _changes.add(SessionOpened(session));
    // Pruning happens on the end the host already observes, not on a timer.
    unawaited(session.ended.then((_) => _pruneEnded()));
    return session;
  }

  /// Forgets the oldest ended sessions beyond [keepEndedSessions]. Running ones
  /// are never touched, however many there are.
  void _pruneEnded() {
    final ended = [
      for (final session in _sessions.values)
        if (session.lifecycle.hasEnded) session,
    ];
    if (ended.length <= keepEndedSessions) return;
    ended.sort((a, b) {
      final left = a.lifecycle.endedAt;
      final right = b.lifecycle.endedAt;
      if (left == null || right == null) return 0;
      return left.compareTo(right);
    });
    for (final session in ended.take(ended.length - keepEndedSessions)) {
      _sessions.remove(session.id);
      session.recorder?.close();
      store?.forget(session.id);
    }
  }

  /// How many sessions have ended and are still readable.
  int get endedCount =>
      _sessions.values.where((session) => session.lifecycle.hasEnded).length;

  List<SessionSummary> list() {
    final observedAt = _now();
    return [
      for (final session in _sessions.values)
        SessionSummary(
          id: session.id,
          argv: session.request.argv,
          workingDirectory: session.request.workingDirectory,
          pid: session.pid,
          columns: session.columns,
          rows: session.rows,
          startedAt: session.startedAt,
          observedAt: observedAt,
          totalBytes: session.backlog.totalBytes,
          firstAvailableOffset: session.backlog.firstAvailableOffset,
          lifecycle: session.lifecycle,
          writeHolder: session.token.holder?.clientId,
        ),
    ];
  }

  /// A client that went away holds nothing. Its sessions keep running.
  void forgetClient(String clientId) {
    for (final session in _sessions.values) {
      session.token.releaseIfHeldBy(clientId);
    }
  }

  /// Ends a session and drops it. Explicit, never a side effect of a disconnect.
  Future<SessionLifecycle> close(String id, {int signal = 15}) async {
    final session = require(id);
    // Taken before the terminate: whether this close is what ended the process,
    // or only lets go of the record of one that had already ended. Marked on
    // the session, so the exit the signal causes is reported as the close's.
    final endedByClose = session.markCloseRequested();
    final end = await session.terminate(signal: signal);
    _sessions.remove(id);
    // Closed on purpose, so the record goes too; a disconnect never reaches here.
    store?.forget(id);
    _changes.add(SessionClosed(session, end, endedByClose: endedByClose));
    return end;
  }

  /// Ends every session because this host is stopping. Not [close] for each:
  /// closing forgets the record, and the record is what survives a shutdown.
  Future<void> shutdown() async {
    // Together, or sixteen stubborn shells cost sixteen reap bounds in a row.
    await Future.wait([
      for (final session in _sessions.values.toList())
        session.terminate(signal: 15),
    ]);
  }
}
