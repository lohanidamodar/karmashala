import 'package:agent_cli/process.dart';

import '../domain/project_check.dart';

/// How one check's command ended: its exit code and last rows, or why it never
/// ran. A refusal is never a pass and never a fail.
class CheckExecution {
  const CheckExecution.ran({required this.exitCode, this.tail = const []})
    : refusal = null;

  const CheckExecution.refused(String this.refusal)
    : exitCode = null,
      tail = const [];

  final String? refusal;

  /// Null when the command stopped without an exit code anybody observed.
  final int? exitCode;
  final List<String> tail;
}

/// Where a check's command runs: a visible pane in the app, a session the
/// host owns in the daemon. [title] names that place.
abstract interface class CheckCommandRunner {
  /// Runs [check] in [directory] and waits for it to stop.
  Future<CheckExecution> execute(
    ProjectCheck check, {
    required EnvironmentPath directory,
    required String title,
  });
}
