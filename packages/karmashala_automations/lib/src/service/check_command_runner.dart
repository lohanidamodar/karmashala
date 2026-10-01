import 'package:agent_cli/process.dart';

import '../domain/project_check.dart';

/// How one check's command ended: its exit code and last rows, or why it never
/// ran. A refusal is never a pass and never a fail.
class CheckExecution {
  const CheckExecution.ran({
    required this.exitCode,
    this.tail = const [],
    this.transcript,
    this.columns,
    this.transcriptTruncated = false,
  }) : refusal = null;

  const CheckExecution.refused(String this.refusal)
    : exitCode = null,
      tail = const [],
      transcript = null,
      columns = null,
      transcriptTruncated = false;

  final String? refusal;

  /// Null when the command stopped without an exit code anybody observed.
  final int? exitCode;
  final List<String> tail;

  /// Everything it printed, for parsing — [tail] is only the last screenful.
  final String? transcript;

  /// The terminal width [transcript] was wrapped at, when it ran in one.
  final int? columns;

  /// [transcript] lost its start to the output ring.
  final bool transcriptTruncated;
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
