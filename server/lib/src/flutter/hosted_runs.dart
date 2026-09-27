import 'dart:async';
import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

import '../domain/host_session.dart';
import '../domain/screen_session.dart';
import '../domain/session_registry.dart';
import '../domain/uuid.dart';
import '../pty/pty.dart';
import '../ssh/ssh_domain.dart' show RemoteSession, RemoteSessionRefused, RemoteSessions;

/// Whether a hosted run's process is still going. `unknown` is a run whose
/// session the registry no longer holds — never read as "finished".
enum HostedRunLiveness { running, finished, unknown }

/// A command the server could not host, in words.
class HostedRunRefused implements Exception {
  const HostedRunRefused(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Commands the server runs as sessions of its own (slice 3d) — a Flutter run
/// or gate, a project's build — so any client can attach a pane and the run
/// outlives every client. The record stays after the end, until pruned. On
/// an SSH box (slice 5d) the run is a session of the box's Karmashala host,
/// under the same id; the server keeps a copy of its screen ([remote]).
class HostedRuns {
  HostedRuns({
    required this.registry,
    required void Function(List<DataChange> changes) tell,
    String Function()? newId,
    DateTime Function()? clock,
    bool? windows,
    this.keep = 50,
    this.remote,
  }) : _tell = tell,
       _newId = newId ?? newUuid,
       _now = clock ?? _utcNow,
       _windows = windows ?? Platform.isWindows;

  final SessionRegistry registry;

  /// Sessions on SSH boxes; null runs nothing there.
  final RemoteSessions? remote;
  final void Function(List<DataChange> changes) _tell;
  final String Function() _newId;
  final DateTime Function() _now;
  final bool _windows;

  /// How many records are kept; the oldest ended ones go first.
  final int keep;

  final _runs = <String, HostedRun>{};

  static DateTime _utcNow() => DateTime.now().toUtc();

  List<HostedRun> get runs => List.unmodifiable(_runs.values);

  HostedRun? byId(String runId) => _runs[runId];

  /// Why the server cannot run a command in [environment], or null.
  String? refusalFor(
    ExecutionEnvironment environment,
  ) => switch (environment.kind) {
    EnvironmentKind.ssh when !(remote?.reaches(environment) ?? false) =>
      '${environment.name} is an SSH machine this Karmashala server does '
          'not reach.',
    EnvironmentKind.ssh => null,
    EnvironmentKind.wsl when !_windows =>
      '${environment.name} is a WSL distribution, and this server is not '
          'on Windows, so it cannot reach it.',
    EnvironmentKind.localPosix when _windows =>
      '${environment.name} is not this Windows server\'s own environment.',
    EnvironmentKind.windowsNative when !_windows =>
      '${environment.name} is a Windows environment, and this server is '
          'not on Windows.',
    _ => null,
  };

  /// Starts [argv] in [directory] as a hosted session — here, or on the SSH
  /// box [environment] names — and records it. Throws [HostedRunRefused] for
  /// an environment the server does not run in, or a process that could not
  /// be started.
  Future<HostedRun> start({
    required List<String> argv,
    required EnvironmentPath directory,
    required ExecutionEnvironment environment,
    required String title,
    required HostedRunFamily family,
    void Function(HostedRun run)? onEnded,
    Map<String, String> variables = const {},
  }) async {
    final refused = refusalFor(environment);
    if (refused != null) throw HostedRunRefused(refused);
    final runId = _newId();
    final sessionId = hostedRunSessionId(hostedRunPaneId(runId));
    if (environment.kind == EnvironmentKind.ssh) {
      final RemoteSession session;
      try {
        session = (await remote!.open(
          environment,
          sessionId: sessionId,
          argv: argv,
          workingDirectory: directory.path,
          variables: variables,
          columns: 120,
          rows: 40,
        )).session;
      } on RemoteSessionRefused catch (error) {
        throw HostedRunRefused(
          '"${argv.join(' ')}" could not be started: ${error.message}',
        );
      }
      return _record(runId, title, family, session, onEnded);
    }
    final PtySpawnRequest request;
    if (environment.kind == EnvironmentKind.wsl) {
      final invocation = buildWslInvocation(
        environment.wslDistribution ?? '',
        CommandRequest(
          executable: argv.first,
          arguments: argv.skip(1).toList(),
          workingDirectory: directory,
        ),
      );
      request = PtySpawnRequest(
        argv: [invocation.executable, ...invocation.arguments],
        environment: const {'TERM': 'xterm-256color'},
        columns: 120,
        rows: 40,
      );
    } else {
      request = PtySpawnRequest(
        argv: argv,
        workingDirectory: directory.path,
        // Laid over the server's own: `ANDROID_HOME`, so `flutter run`
        // reaches the same adb as the server's device tools (slice 4a).
        environment: {'TERM': 'xterm-256color', ...variables},
        columns: 120,
        rows: 40,
      );
    }
    final HostSession session;
    try {
      session = registry.open(sessionId, request);
    } on Object catch (error) {
      throw HostedRunRefused(
        '"${argv.join(' ')}" could not be started: $error',
      );
    }
    return _record(runId, title, family, session, onEnded);
  }

  HostedRun _record(
    String runId,
    String title,
    HostedRunFamily family,
    ScreenSession session,
    void Function(HostedRun run)? onEnded,
  ) {
    final run = HostedRun(
      runId: runId,
      title: title,
      family: family,
      startedAt: _now(),
    );
    _runs[runId] = run;
    _tell([HostedRunChanged(run)]);
    unawaited(
      (session is HostSession ? session.drained : session.ended).then((end) {
        final current = _runs[runId];
        if (current == null) return;
        final ended = HostedRun(
          runId: runId,
          title: current.title,
          family: current.family,
          startedAt: current.startedAt,
          endedAt: end.endedAt?.toUtc() ?? _now(),
          exitCode: end.exitCode,
        );
        _runs[runId] = ended;
        _tell([HostedRunChanged(ended)]);
        onEnded?.call(ended);
        _prune();
      }),
    );
    _prune();
    return run;
  }

  /// The session [runId] runs in, while the registry still holds it — or
  /// the server's copy of it on a box.
  ScreenSession? sessionOf(String runId) {
    if (!_runs.containsKey(runId)) return null;
    final id = hostedRunSessionId(hostedRunPaneId(runId));
    return registry.find(id) ?? remote?.byId(id);
  }

  HostedRunLiveness livenessOf(String runId) {
    final session = sessionOf(runId);
    if (session == null) return HostedRunLiveness.unknown;
    return session.lifecycle.hasEnded
        ? HostedRunLiveness.finished
        : HostedRunLiveness.running;
  }

  /// The bottom [lines] rows of [runId]'s screen, or empty when gone.
  List<String> tailOf(String runId, {int lines = 80}) =>
      sessionOf(runId)?.tailText(lines) ?? const [];

  /// Fires on each chunk [runId] writes from now on; ends with the output.
  Stream<void> outputOf(String runId) {
    final session = sessionOf(runId);
    return switch (session) {
      null => const Stream<void>.empty(),
      final HostSession here =>
        here.readFrom(here.backlog.totalBytes).map((_) {}),
      final RemoteSession box => box.output,
      _ => const Stream<void>.empty(),
    };
  }

  /// Ends [runId]'s process — stopped, not detached — and keeps its record,
  /// so a pane still shows how it ended.
  Future<HostedRun?> stop(String runId) async {
    final run = _runs[runId];
    if (run == null) return null;
    final session = sessionOf(runId);
    if (session != null && !session.lifecycle.hasEnded) {
      if (session is HostSession) {
        session.markCloseRequested();
        await session.terminate();
      } else {
        try {
          await remote?.close(session.id);
        } on RemoteSessionRefused {
          // The box went; its session is the box's to end.
        }
      }
    }
    return _runs[runId];
  }

  void _prune() {
    final ended = [
      for (final run in _runs.values)
        if (!run.isLive) run,
    ];
    final over = _runs.length - keep;
    if (over <= 0) return;
    ended.sort((a, b) => a.startedAt.compareTo(b.startedAt));
    final removed = <DataChange>[];
    for (final run in ended.take(over)) {
      _runs.remove(run.runId);
      removed.add(HostedRunRemoved(run.runId));
    }
    if (removed.isNotEmpty) _tell(removed);
  }
}
