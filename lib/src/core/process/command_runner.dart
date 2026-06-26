import '../../features/environments/domain/environment_path.dart';
import 'process_handle.dart';

/// A command to execute, described independently of where it runs.
///
/// The [workingDirectory], when given, is an [EnvironmentPath] in the runner's
/// own environment — paths are never bare strings (constraints 7 & 8).
class CommandRequest {
  const CommandRequest({
    required this.executable,
    this.arguments = const [],
    this.workingDirectory,
  });

  final String executable;
  final List<String> arguments;
  final EnvironmentPath? workingDirectory;

  @override
  String toString() =>
      'CommandRequest($executable ${arguments.join(' ')}'
      '${workingDirectory == null ? '' : ' @${workingDirectory!.path}'})';
}

/// The result of running a [CommandRequest] to completion.
class CommandResult {
  const CommandResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;

  /// Whether the process exited successfully (exit code 0).
  bool get ok => exitCode == 0;
}

/// Raised when a command cannot be executed (e.g. the executable is missing or
/// the environment is unavailable). A non-zero exit code is **not** an error —
/// that is reported via [CommandResult.exitCode].
class CommandException implements Exception {
  CommandException(this.message, {this.cause});
  final String message;
  final Object? cause;
  @override
  String toString() =>
      'CommandException: $message${cause == null ? '' : ' ($cause)'}';
}

/// The single abstraction through which **all** process execution flows.
///
/// Features depend on a [CommandRunner], never on `dart:io` `Process` directly
/// (architecture constraint 6). Each runner targets one execution environment
/// ([environmentId]); implementations: `WindowsCommandRunner`,
/// `WslCommandRunner`, and `FakeCommandRunner` (tests).
///
/// Streaming execution (for live agent sessions) is added in Loop 6; Loop 3
/// needs only run-to-completion [run].
abstract interface class CommandRunner {
  /// Id of the execution environment this runner targets.
  String get environmentId;

  /// Runs [request] to completion and returns its captured output.
  ///
  /// Throws [CommandException] if the process cannot be started.
  Future<CommandResult> run(CommandRequest request);

  /// Starts [request] as a long-lived, streaming process and returns a handle.
  ///
  /// Used for interactive agent stdio protocols (Loop 7+). Throws
  /// [CommandException] if the process cannot be started.
  Future<ProcessHandle> start(CommandRequest request);
}
