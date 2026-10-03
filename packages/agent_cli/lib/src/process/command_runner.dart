import '../environments/environment_path.dart';
import './process_handle.dart';

/// A command to execute, described independently of where it runs.
///
/// The [workingDirectory], when given, is an [EnvironmentPath] in the runner's
/// own environment — paths are never bare strings (constraints 7 & 8).
class CommandRequest {
  const CommandRequest({
    required this.executable,
    this.arguments = const [],
    this.workingDirectory,
    this.runInShell = false,
    this.stdinText,
    this.timeout,
    this.environment = const {},
    this.removedEnvironment = const {},
  });

  final String executable;
  final List<String> arguments;
  final EnvironmentPath? workingDirectory;

  /// How long `run` waits for the exit before killing the child and throwing a
  /// [CommandException]. Null — the default — waits forever, as `Process.run` does.
  final Duration? timeout;

  /// Text to hand the process on **stdin**, which is then closed.
  ///
  /// Null — the default, and what every existing caller passes — is the
  /// behaviour `Process.run` has always had: stdin is closed immediately and
  /// the child reads nothing.
  ///
  /// It exists because a command line is not a place to put a document. Windows
  /// caps one at 32,767 characters, so anything the size of a transcript has to
  /// arrive some other way, and the CLIs that take one say so themselves —
  /// `codex exec`'s `--help` names the pipe, and `claude -p` is documented as
  /// being for them.
  ///
  /// Encoded as UTF-8 rather than [systemEncoding]: this is a payload this app
  /// composed and knows the encoding of, and the code page a Windows console
  /// happens to be on is not it.
  final String? stdinText;

  /// Variables set for this process, over the environment it would inherit.
  /// Every runner honours them where the process runs: in WSL they cross by
  /// `WSLENV`, over SSH as a quoted `env` prefix.
  final Map<String, String> environment;

  /// Variables this process must not inherit, applied before [environment].
  final Set<String> removedEnvironment;

  /// Run via the system shell. Needed to launch Windows **app-execution
  /// aliases** (e.g. `wt.exe`, Windows Terminal), which `Process.start` cannot
  /// resolve on its own.
  final bool runInShell;

  @override
  String toString() =>
      'CommandRequest($executable ${arguments.join(' ')}'
      '${workingDirectory == null ? '' : ' @${workingDirectory!.path}'}'
      '${stdinText == null ? '' : ' <${stdinText!.length} chars'}'
      '${timeout == null ? '' : ' within ${timeout!.inSeconds}s'})';
}

/// `env -u NAME … NAME=value …`, the words that give a POSIX command [request]'s
/// environment; empty when the request names none. Unquoted: a caller that
/// hands them to a shell quotes each one.
List<String> posixEnvironmentPrefix(CommandRequest request) {
  if (request.environment.isEmpty && request.removedEnvironment.isEmpty) {
    return const [];
  }
  return [
    'env',
    for (final name in request.removedEnvironment) ...['-u', name],
    for (final entry in request.environment.entries)
      '${entry.key}=${entry.value}',
  ];
}

/// The bound on a probe that only discovers — `where`, `command -v`,
/// `--version`, `wsl.exe --list`. Generous, because it is a ceiling for a
/// wedged tool, not a budget; without one a stuck `wsl.exe` hangs discovery forever.
const Duration kProbeTimeout = Duration(seconds: 60);

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
/// ([environmentId]); implementations: `LocalCommandRunner`,
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
