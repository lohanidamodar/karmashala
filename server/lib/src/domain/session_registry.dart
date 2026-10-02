import 'dart:async';
import 'dart:io' show Platform;

import '../acp/acp_session_runtime.dart';
import '../pty/pty.dart';
import 'host_session.dart';
import 'hosted_process.dart';
import 'output_backlog.dart';
import 'registry_change.dart';
import 'package:karmashala_host_protocol/protocol.dart';
import 'screen_session.dart';
import 'session_recorder.dart';

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

/// The id names a session this host runs, but over the Agent Client Protocol:
/// there is no terminal to attach to, type into or resize.
class SessionHasNoTerminal extends UnknownSession {
  const SessionHasNoTerminal(super.id);
  @override
  String toString() =>
      'session "$id" runs its agent over the Agent Client Protocol and has no '
      'terminal to attach to; read its transcript instead';
}

/// Every process this host owns under a session id: its PTYs, and the agents
/// it speaks to over ACP. Sessions are never removed because a client went
/// away — only when they have ended and somebody asks to forget them.
class SessionRegistry {
  SessionRegistry({
    required PtyLauncher launcher,
    this.store,
    this.backlogCapacityBytes = OutputBacklog.defaultCapacityBytes,
    this.keepEndedSessions = defaultKeepEndedSessions,
    DateTime Function()? clock,
    String? hostname,
  }) : _launcher = launcher,
       _now = clock ?? DateTime.now,
       hostname = hostname ?? Platform.localHostname {
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

  /// This machine's name: a shell's OSC 7 naming another host is not a
  /// directory here (`ScreenFacts`).
  final String hostname;
  final DateTime Function() _now;
  final _processes = <String, HostedProcess>{};

  // Synchronous, so a listener sees an opened session before any of its exit.
  final _changes = StreamController<RegistryChange>.broadcast(sync: true);

  /// Sessions opened and closed on request, as they happen.
  Stream<RegistryChange> get changes => _changes.stream;

  /// Every process held, whichever kind.
  Iterable<HostedProcess> get processes => _processes.values;

  /// The terminals held: what a pane attaches to and a recording reads.
  Iterable<HostSession> get sessions => [
    for (final process in _processes.values)
      if (process is PtyProcess) process.session,
  ];

  /// Every process as a screen, for a status reader and a run's tail.
  Iterable<ScreenSession> get screens => [
    for (final process in _processes.values) process.screen,
  ];

  /// The terminal under [id], or null: missing, or an ACP session.
  HostSession? find(String id) => switch (_processes[id]) {
    PtyProcess(:final session) => session,
    _ => null,
  };

  HostedProcess? findProcess(String id) => _processes[id];

  /// The ACP runtime under [id], or null: missing, or a terminal.
  AcpSessionRuntime? findAcp(String id) => switch (_processes[id]) {
    AcpProcess(:final runtime) => runtime,
    _ => null,
  };

  /// What the previous host left behind, read once at construction. A record
  /// that says *running* comes back ended with no exit code and a reason, never
  /// as a session somebody could type into.
  void _restore() {
    final source = store;
    if (source == null) return;
    for (final persisted in source.restore()) {
      _processes[persisted.id] = PtyProcess(
        HostSession.restored(
          id: persisted.id,
          request: persisted.request,
          startedAt: persisted.startedAt,
          restoredBacklog: persisted.backlog,
          lifecycle: persisted.lifecycle,
        ),
      );
    }
    // The bound applies across restarts too, or sixteen crashes accumulate.
    _pruneEnded();
  }

  /// The terminal under [id]; throws [UnknownSession] for none, and
  /// [SessionHasNoTerminal] for an ACP session.
  HostSession require(String id) => switch (_processes[id]) {
    PtyProcess(:final session) => session,
    AcpProcess() => throw SessionHasNoTerminal(id),
    null => throw UnknownSession(id),
  };

  HostedProcess requireProcess(String id) =>
      _processes[id] ?? (throw UnknownSession(id));

  /// Opens under an id the client chose, so a pane reattaches to its own
  /// session without the host inventing names.
  HostSession open(String id, PtySpawnRequest request) {
    _vacate(id);
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
      hostname: hostname,
    );
    _add(id, PtyProcess(session));
    return session;
  }

  /// Holds [runtime] under [id] — the caller then starts it. Nothing of it
  /// is recorded on disk: its conversation is in the store already.
  AcpSessionRuntime openAcp(String id, AcpSessionRuntime runtime) {
    _vacate(id);
    _add(id, AcpProcess(runtime));
    return runtime;
  }

  /// An ended session under [id] is a record, not an owner; refusing would
  /// leave the id unusable until somebody closed it explicitly.
  void _vacate(String id) {
    final existing = _processes[id];
    if (existing == null) return;
    if (!existing.lifecycle.hasEnded) throw SessionAlreadyExists(id);
    _processes.remove(id);
    existing.release();
    store?.forget(id);
  }

  void _add(String id, HostedProcess process) {
    _processes[id] = process;
    _changes.add(SessionOpened(process));
    // Pruning happens on the end the host already observes, not on a timer.
    unawaited(process.ended.then((_) => _pruneEnded()));
  }

  /// Forgets the oldest ended sessions beyond [keepEndedSessions]. Running ones
  /// are never touched, however many there are.
  void _pruneEnded() {
    final ended = [
      for (final process in _processes.values)
        if (process.lifecycle.hasEnded) process,
    ];
    if (ended.length <= keepEndedSessions) return;
    ended.sort((a, b) {
      final left = a.lifecycle.endedAt;
      final right = b.lifecycle.endedAt;
      if (left == null || right == null) return 0;
      return left.compareTo(right);
    });
    for (final process in ended.take(ended.length - keepEndedSessions)) {
      _processes.remove(process.id);
      process.release();
      store?.forget(process.id);
    }
  }

  /// How many sessions have ended and are still readable.
  int get endedCount =>
      _processes.values.where((process) => process.lifecycle.hasEnded).length;

  /// The terminals, as `list` answers: an ACP session has no grid or backlog
  /// to report and is left out.
  List<SessionSummary> list() {
    final observedAt = _now();
    return [
      for (final session in sessions)
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
    for (final session in sessions) {
      session.token.releaseIfHeldBy(clientId);
    }
  }

  /// Ends a session and drops it. Explicit, never a side effect of a disconnect.
  Future<SessionLifecycle> close(String id, {int signal = 15}) async {
    final process = requireProcess(id);
    // Taken before the terminate: whether this close is what ended the process,
    // or only lets go of the record of one that had already ended. Marked on
    // the session, so the exit the signal causes is reported as the close's.
    final endedByClose = process.markCloseRequested();
    final end = await process.terminate(signal: signal);
    _processes.remove(id);
    // Closed on purpose, so the record goes too; a disconnect never reaches here.
    store?.forget(id);
    _changes.add(SessionClosed(process, end, endedByClose: endedByClose));
    return end;
  }

  /// Ends every session because this host is stopping. Not [close] for each:
  /// closing forgets the record, and the record is what survives a shutdown.
  Future<void> shutdown() async {
    // Together, or sixteen stubborn shells cost sixteen reap bounds in a row.
    await Future.wait([
      for (final process in _processes.values.toList()) process.stopWithHost(),
    ]);
  }
}
