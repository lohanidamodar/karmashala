import 'package:agent_cli/process.dart';
import 'package:karmashala_automations/check_runner.dart';
import 'package:karmashala_automations/checks.dart';

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
  }) : _stopping = stopping ?? _never;

  final SessionRegistry registry;
  final String Function() newId;

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
    final id = '$kCheckSessionPrefix${newId()}';
    final session = registry.open(
      id,
      PtySpawnRequest(
        argv: check.command,
        workingDirectory: directory.path,
        environment: const {'TERM': 'xterm-256color'},
        columns: 160,
        rows: 50,
      ),
    );
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
}
