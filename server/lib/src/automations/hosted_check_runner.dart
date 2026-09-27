import 'package:agent_cli/process.dart';
import 'package:karmashala_automations/check_runner.dart';
import 'package:karmashala_automations/checks.dart';

import '../domain/host_session.dart';
import '../domain/session_registry.dart';
import '../pty/pty.dart';

/// The host session id prefix of a project check. Never `karmashala_…`, so no
/// check is ever read as a session row's process.
const String kCheckSessionPrefix = 'karmashala-check-';

/// How much of a finished check's screen is kept beside its verdict.
const int kCheckRowsRecorded = 400;

/// Runs a check's command as a session this host owns — watchable from any
/// client while it runs — waits for it, and lets its record go after.
class HostedCheckRunner implements CheckCommandRunner {
  HostedCheckRunner({
    required this.registry,
    required this.newId,
    bool Function()? stopping,
    this.remote,
  }) : _stopping = stopping ?? _never;

  final SessionRegistry registry;
  final String Function() newId;

  /// The runner for a directory on an SSH box, or null for one on this
  /// machine. A check there runs as one command over the server's own
  /// connection — no session to watch, its output kept as the tail.
  final CommandRunner? Function(EnvironmentPath directory)? remote;

  /// True once the host is shutting down: a check it killed on the way out
  /// failed nothing, so its exit is not read as a verdict.
  final bool Function() _stopping;

  static bool _never() => false;

  @override
  Future<CheckExecution> execute(
    ProjectCheck check, {
    required EnvironmentPath directory,
    required String title,
  }) async {
    final runner = remote?.call(directory);
    if (runner != null) return _runRemotely(runner, check, directory);
    final id = '$kCheckSessionPrefix${newId()}';
    final HostSession session;
    try {
      // Laid over the host's own environment (`PtySpawnRequest.environment`),
      // which is the app's: the host is started by the app and inherits it,
      // as the app's own check panes did. A bare argv[0] is found on its PATH.
      session = registry.open(
        id,
        PtySpawnRequest(
          argv: check.command,
          workingDirectory: directory.path,
          environment: const {'TERM': 'xterm-256color'},
          columns: 160,
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
    final end = await session.drained;
    if (_stopping()) {
      return CheckExecution.refused(
        '"${check.name}" was stopped because the session host was shutting '
        'down. Whether the work still stands is unknown, not proven.',
      );
    }
    final tail = session.tailText(kCheckRowsRecorded);
    try {
      await registry.close(id);
    } on UnknownSession {
      // Pruned already; the verdict is what matters.
    }
    return CheckExecution.ran(exitCode: end.exitCode, tail: tail);
  }

  Future<CheckExecution> _runRemotely(
    CommandRunner runner,
    ProjectCheck check,
    EnvironmentPath directory,
  ) async {
    if (check.command.isEmpty) {
      return CheckExecution.refused(
        '"${check.name}" has no command. Whether the work still stands is '
        'unknown, not proven.',
      );
    }
    final CommandResult result;
    try {
      result = await runner.run(
        CommandRequest(
          executable: check.command.first,
          arguments: check.command.sublist(1),
          workingDirectory: directory,
        ),
      );
    } on Object catch (error) {
      return CheckExecution.refused(
        '"${check.name}" did not run: $error. Whether the work still stands '
        'is unknown, not proven.',
      );
    }
    if (_stopping()) {
      return CheckExecution.refused(
        '"${check.name}" was stopped because the server was shutting down. '
        'Whether the work still stands is unknown, not proven.',
      );
    }
    final lines = '${result.stdout}${result.stderr}'.split('\n');
    return CheckExecution.ran(
      exitCode: result.exitCode,
      tail: lines.length <= kCheckRowsRecorded
          ? lines
          : lines.sublist(lines.length - kCheckRowsRecorded),
    );
  }
}
