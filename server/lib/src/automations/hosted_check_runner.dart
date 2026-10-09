import 'dart:async';
import 'dart:convert';

import 'package:agent_cli/process.dart';
import 'package:karmashala_automations/check_runner.dart';
import 'package:karmashala_automations/checks.dart';

import '../domain/host_session.dart';
import '../domain/session_registry.dart';
import '../pty/pty.dart';
import '../pty/environment_spawn.dart';
import 'step_runners.dart' show exactRunner;

/// The host session id prefix of a project check. Never `karmashala_…`, so no
/// check is ever read as a session row's process.
const String kCheckSessionPrefix = 'karmashala-check-';

/// How much of a finished check's screen is kept beside its verdict.
const int kCheckRowsRecorded = 400;

/// The width a check's terminal wraps at, which its output parser undoes.
const int kCheckColumns = 160;

/// Set on every check's process, so its whole tree can be found and ended
/// where no process handle reaches: inside a WSL distribution, on an SSH box.
const String kCheckMarkerVariable = 'KARMASHALA_CHECK_ID';

/// How long a stopped check's command is given to report what it printed.
const Duration kCheckStopGrace = Duration(seconds: 10);

/// `sh` that kills, on Linux, every process whose environment carries
/// [marker] as [kCheckMarkerVariable] — the check's tree, however it forked or
/// detached. Twice, for children forked during the first pass.
String checkTreeKillScript(String marker) {
  final quoted =
      "'${'$kCheckMarkerVariable=$marker'.replaceAll("'", r"'\''")}'";
  const pids = r"tr '\0' '\n' | sed -n 's#^/proc/\([0-9]*\)/environ$#\1#p'";
  final pass =
      'grep -laxzF $quoted /proc/[0-9]*/environ 2>/dev/null | $pids '
      '| xargs kill -KILL 2>/dev/null';
  return '$pass\n$pass\ntrue';
}

/// Runs a check's command as a session this host owns — watchable from any
/// client while it runs — waits for it, and lets its record go after. A check
/// past its [ProjectCheck.timeLimit], or cancelled, is ended with everything
/// it started.
class HostedCheckRunner implements CheckCommandRunner {
  HostedCheckRunner({
    required this.registry,
    required this.newId,
    bool Function()? stopping,
    this.remote,
    this.environmentOf,
    CommandRunner Function(ExecutionEnvironment environment)? distroRunner,
  }) : _stopping = stopping ?? _never,
       _distroRunner =
           distroRunner ??
           ((environment) =>
               exactRunner(environment, const CommandRunnerFactory()));

  final SessionRegistry registry;
  final String Function() newId;

  /// The runner for a directory on an SSH box, or null for one on this
  /// machine. A check there runs as one command over the server's own
  /// connection — no session to watch, its output kept as the tail.
  final CommandRunner? Function(EnvironmentPath directory)? remote;

  /// The environment a directory names, so a check in a WSL distribution runs
  /// through `wsl.exe` (slice 5a); null: this machine's own.
  final ExecutionEnvironment? Function(String environmentId)? environmentOf;

  /// A shell inside a WSL distribution, for ending a check's Linux processes:
  /// killing `wsl.exe` here leaves them running there.
  final CommandRunner Function(ExecutionEnvironment environment) _distroRunner;

  /// True once the host is shutting down: a check it killed on the way out
  /// failed nothing, so its exit is not read as a verdict.
  final bool Function() _stopping;

  static bool _never() => false;

  @override
  Future<CheckExecution> execute(
    ProjectCheck check, {
    required EnvironmentPath directory,
    required String title,
    Future<void>? cancelled,
  }) async {
    final runner = remote?.call(directory);
    if (runner != null) {
      return _runRemotely(runner, check, directory, cancelled);
    }
    final id = '$kCheckSessionPrefix${newId()}';
    final environment = environmentOf?.call(directory.environmentId);
    final HostSession session;
    try {
      // Laid over the host's own environment (`PtySpawnRequest.environment`),
      // which is the app's: the host is started by the app and inherits it,
      // as the app's own check panes did. A bare argv[0] is found on its PATH.
      session = registry.open(
        id,
        spawnRequestIn(
          environment,
          argv: check.command,
          directory: directory.path,
          variables: {kCheckMarkerVariable: id},
          columns: kCheckColumns,
          rows: 50,
        ),
      );
    } on PtyException catch (error) {
      // Said as what it is — the command could not be started — never as an
      // exit code nobody observed.
      return CheckExecution.refused(
        '"${check.name}" did not run: ${error.message}'
        '${error.errno == null ? '' : ' (errno ${error.errno})'}. Whether the '
        'work still stands is unknown, not proven.',
      );
    }
    final stop = await _firstOf(session.drained, check.timeLimit, cancelled);
    if (stop != _Stop.exited) {
      if (environment?.kind == EnvironmentKind.wsl) {
        await _killInDistro(environment!, id);
      }
    }
    int? exitCode;
    if (stop == _Stop.exited) exitCode = (await session.drained).exitCode;
    final tail = session.tailText(kCheckRowsRecorded);
    final printed = session.backlog.since(0);
    try {
      // On Windows the tree, children first; elsewhere the whole session.
      await registry.close(id, signal: 9);
    } on UnknownSession {
      // Pruned already; the verdict is what matters.
    }
    if (_stopping()) {
      return CheckExecution.refused(
        '"${check.name}" was stopped because the session host was shutting '
        'down. Whether the work still stands is unknown, not proven.',
      );
    }
    final transcript = utf8.decode(printed.bytes, allowMalformed: true);
    return switch (stop) {
      _Stop.exited => CheckExecution.ran(
        exitCode: exitCode,
        tail: tail,
        transcript: transcript,
        columns: kCheckColumns,
        transcriptTruncated: printed.droppedBytes > 0,
      ),
      _Stop.timedOut => CheckExecution.timedOut(
        check.timeLimit,
        tail: tail,
        transcript: transcript,
        columns: kCheckColumns,
        transcriptTruncated: printed.droppedBytes > 0,
      ),
      _Stop.cancelled => _cancelledRefusal(check),
    };
  }

  Future<CheckExecution> _runRemotely(
    CommandRunner runner,
    ProjectCheck check,
    EnvironmentPath directory,
    Future<void>? cancelled,
  ) async {
    if (check.command.isEmpty) {
      return CheckExecution.refused(
        '"${check.name}" has no command. Whether the work still stands is '
        'unknown, not proven.',
      );
    }
    final marker = '$kCheckSessionPrefix${newId()}';
    final running = runner.run(
      CommandRequest(
        executable: check.command.first,
        arguments: check.command.sublist(1),
        workingDirectory: directory,
        environment: {kCheckMarkerVariable: marker},
      ),
    );
    final stop = await _firstOf(running, check.timeLimit, cancelled);
    CommandResult? result;
    try {
      if (stop == _Stop.exited) {
        result = await running;
      } else {
        // The channel closing does not end a command with no terminal, so
        // its tree is found by marker and killed; the run then reports what
        // it printed.
        await _kill(runner, marker);
        result = await running.timeout(kCheckStopGrace);
      }
    } on TimeoutException {
      result = null;
    } on Object catch (error) {
      if (stop == _Stop.exited) {
        return CheckExecution.refused(
          '"${check.name}" did not run: $error. Whether the work still stands '
          'is unknown, not proven.',
        );
      }
      result = null;
    }
    if (_stopping()) {
      return CheckExecution.refused(
        '"${check.name}" was stopped because the server was shutting down. '
        'Whether the work still stands is unknown, not proven.',
      );
    }
    final printed = result == null ? '' : '${result.stdout}${result.stderr}';
    final lines = printed.split('\n');
    final tail = lines.length <= kCheckRowsRecorded
        ? lines
        : lines.sublist(lines.length - kCheckRowsRecorded);
    return switch (stop) {
      _Stop.exited => CheckExecution.ran(
        exitCode: result!.exitCode,
        transcript: printed,
        tail: tail,
      ),
      _Stop.timedOut => CheckExecution.timedOut(
        check.timeLimit,
        transcript: printed,
        tail: tail,
      ),
      _Stop.cancelled => _cancelledRefusal(check),
    };
  }

  Future<void> _killInDistro(ExecutionEnvironment environment, String marker) =>
      _kill(_distroRunner(environment), marker);

  /// Best effort: a box or distribution that cannot be reached to kill in
  /// cannot be helped from here, and the verdict is already decided.
  Future<void> _kill(CommandRunner runner, String marker) async {
    try {
      await runner.run(
        CommandRequest(
          executable: 'sh',
          arguments: ['-c', checkTreeKillScript(marker)],
          timeout: kCheckStopGrace,
        ),
      );
    } on Object {
      // See above.
    }
  }

  static CheckExecution _cancelledRefusal(ProjectCheck check) =>
      CheckExecution.refused(
        '"${check.name}" was cancelled before it finished. Whether the work '
        'still stands is unknown, not proven.',
      );

  static Future<_Stop> _firstOf(
    Future<Object?> exit,
    Duration limit,
    Future<void>? cancelled,
  ) {
    final stop = Completer<_Stop>();
    final timer = Timer(limit, () {
      if (!stop.isCompleted) stop.complete(_Stop.timedOut);
    });
    void exited([Object? _]) {
      if (!stop.isCompleted) stop.complete(_Stop.exited);
    }

    exit.then(exited, onError: (Object _, StackTrace _) => exited());
    cancelled?.then((_) {
      if (!stop.isCompleted) stop.complete(_Stop.cancelled);
    });
    return stop.future.whenComplete(timer.cancel);
  }
}

enum _Stop { exited, timedOut, cancelled }
