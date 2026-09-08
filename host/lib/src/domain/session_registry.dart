import 'dart:async';

import '../pty/pty.dart';
import 'host_session.dart';
import 'output_backlog.dart';
import 'session_lifecycle.dart';

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
    this.backlogCapacityBytes = OutputBacklog.defaultCapacityBytes,
    this.keepEndedSessions = defaultKeepEndedSessions,
    DateTime Function()? clock,
  }) : _launcher = launcher,
       _now = clock ?? DateTime.now;

  /// How many ended sessions are kept around after they finish.
  ///
  /// Not zero, because a pane that reconnects a moment after its command ended
  /// must still be able to read the exit code — dropping it the instant the
  /// child died would turn a real code into "unknown". Not unbounded either:
  /// each one holds up to 4 MiB of backlog, and a week of `terminal_run` would
  /// otherwise accumulate every one of them.
  static const int defaultKeepEndedSessions = 16;

  final PtyLauncher _launcher;
  final int backlogCapacityBytes;
  final int keepEndedSessions;
  final DateTime Function() _now;
  final _sessions = <String, HostSession>{};

  Iterable<HostSession> get sessions => _sessions.values;

  HostSession? find(String id) => _sessions[id];

  HostSession require(String id) {
    final session = _sessions[id];
    if (session == null) throw UnknownSession(id);
    return session;
  }

  /// Opens a session under an id the client chose, so the same pane reattaches
  /// to the same session after a reconnect without the host inventing names.
  HostSession open(String id, PtySpawnRequest request) {
    if (_sessions.containsKey(id)) throw SessionAlreadyExists(id);
    final session = HostSession(
      id: id,
      request: request,
      pty: _launcher.start(request),
      startedAt: _now(),
      backlogCapacityBytes: backlogCapacityBytes,
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
    return end;
  }

  Future<void> shutdown() async {
    final ids = _sessions.keys.toList();
    for (final id in ids) {
      await close(id, signal: 15);
    }
  }
}
