import 'dart:async';

import '../pty/pty.dart';
import 'host_session.dart';
import 'output_backlog.dart';
import 'session_lifecycle.dart';
import 'session_recorder.dart';

/// What `list` answers with. Every field is something the host observed; the
/// reading's own age is the caller's to compute from [observedAt].
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

/// Every session this host owns.
///
/// Sessions are never removed because a client went away — only when they have
/// ended and somebody asks to forget them. That is the difference between this
/// and running the child inside the app.
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

  /// How many ended sessions are kept around after they finish.
  ///
  /// Not zero, because a pane that reconnects a moment after its command ended
  /// must still be able to read the exit code — dropping it the instant the
  /// child died would turn a real code into "unknown". Not unbounded either:
  /// each one holds up to 4 MiB of backlog, and a week of `terminal_run` would
  /// otherwise accumulate every one of them.
  static const int defaultKeepEndedSessions = 16;

  final PtyLauncher _launcher;

  /// Where sessions are kept beyond this process. Null means the host holds
  /// them in memory only, which is what every host did before the local stage
  /// and what a test wants by default.
  final SessionBacklogStore? store;

  final int backlogCapacityBytes;
  final int keepEndedSessions;
  final DateTime Function() _now;
  final _sessions = <String, HostSession>{};

  Iterable<HostSession> get sessions => _sessions.values;

  HostSession? find(String id) => _sessions[id];

  /// What the previous host left behind, put back where a client can attach to
  /// it. Read once, at construction — nothing rescans the directory later.
  ///
  /// A session the record says was **running** is the one this exists for: its
  /// process died with the host that owned it, and it comes back ended with no
  /// exit code and a reason that says exactly that, rather than as a session
  /// somebody could type into.
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
    // The bound applies across a restart too, or a host that crashed sixteen
    // times would come back holding every session any of them ever ran.
    _pruneEnded();
  }

  HostSession require(String id) {
    final session = _sessions[id];
    if (session == null) throw UnknownSession(id);
    return session;
  }

  /// Opens a session under an id the client chose, so the same pane reattaches
  /// to the same session after a reconnect without the host inventing names.
  HostSession open(String id, PtySpawnRequest request) {
    final existing = _sessions[id];
    if (existing != null) {
      // An *ended* session under this id is a record, not an owner: a pane
      // restarted after its process died — or after the host that held it
      // stopped — must be able to start one, and refusing would leave that id
      // unusable until somebody closed it explicitly.
      if (!existing.lifecycle.hasEnded) throw SessionAlreadyExists(id);
      _sessions.remove(id);
      existing.recorder?.close();
      store?.forget(id);
    }
    final startedAt = _now();
    final session = HostSession(
      id: id,
      request: request,
      pty: _launcher.start(request),
      startedAt: startedAt,
      backlogCapacityBytes: backlogCapacityBytes,
      recorder: store?.open(id, request, startedAt),
    );
    _sessions[id] = session;
    // Pruning happens when a session *ends*, not on a timer and not on a scan:
    // the end is an event the host already observes.
    unawaited(session.ended.then((_) => _pruneEnded()));
    return session;
  }

  /// Forgets the oldest ended sessions beyond [keepEndedSessions].
  ///
  /// Running sessions are never touched however many there are: the host's job
  /// is to hold them, and a pane that has not reattached yet is not a session
  /// nobody wants.
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

  /// Ends a session and drops it. Explicit, never a side effect of a
  /// disconnect.
  Future<SessionLifecycle> close(String id, {int signal = 15}) async {
    final session = require(id);
    final end = await session.terminate(signal: signal);
    _sessions.remove(id);
    // Closed on purpose, so the record goes too. A client merely disconnecting
    // never reaches here — that is the whole point of the host.
    store?.forget(id);
    return end;
  }

  /// Ends every session because this host is stopping.
  ///
  /// Deliberately not [close] for each: closing is a client saying *forget
  /// this*, and forgetting the record is what it means. A host shutting down
  /// wants the opposite — the record is the only thing that will survive it, so
  /// each session is terminated, its end written down, and nothing is dropped.
  Future<void> shutdown() async {
    for (final session in _sessions.values.toList()) {
      await session.terminate(signal: 15);
    }
  }
}
