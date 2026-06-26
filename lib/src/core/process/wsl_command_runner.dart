import 'dart:io';

import 'command_runner.dart';
import 'io_process_handle.dart';
import 'process_handle.dart';

/// A `wsl.exe` invocation: the Windows-side executable and arguments that run a
/// command inside a specific WSL distribution.
class WslInvocation {
  const WslInvocation(this.executable, this.arguments);
  final String executable;
  final List<String> arguments;
}

/// Builds the `wsl.exe` command line to run [request] inside [distribution].
///
/// Pure and side-effect free so it can be unit-tested without a real WSL. Uses
/// `--cd` to set the working directory (a WSL path) and `--` to separate WSL's
/// own flags from the target command and its arguments.
WslInvocation buildWslInvocation(String distribution, CommandRequest request) {
  final args = <String>['-d', distribution];
  final cwd = request.workingDirectory;
  if (cwd != null) {
    args
      ..add('--cd')
      ..add(cwd.path);
  }
  args
    ..add('--')
    ..add(request.executable)
    ..addAll(request.arguments);
  return WslInvocation('wsl.exe', args);
}

/// Runs commands inside a named WSL distribution by invoking `wsl.exe` on the
/// Windows host.
class WslCommandRunner implements CommandRunner {
  const WslCommandRunner({
    required this.environmentId,
    required this.distribution,
  });

  @override
  final String environmentId;

  /// The WSL distribution name (e.g. `Ubuntu`).
  final String distribution;

  @override
  Future<CommandResult> run(CommandRequest request) async {
    final invocation = buildWslInvocation(distribution, request);
    try {
      final result = await Process.run(
        invocation.executable,
        invocation.arguments,
      );
      return CommandResult(
        exitCode: result.exitCode,
        stdout: result.stdout as String,
        stderr: result.stderr as String,
      );
    } on ProcessException catch (e) {
      throw CommandException(
        'Failed to run "${request.executable}" in WSL "$distribution"',
        cause: e,
      );
    }
  }

  @override
  Future<ProcessHandle> start(CommandRequest request) async {
    final invocation = buildWslInvocation(distribution, request);
    try {
      final process = await Process.start(
        invocation.executable,
        invocation.arguments,
      );
      return IoProcessHandle(process);
    } on ProcessException catch (e) {
      throw CommandException(
        'Failed to start "${request.executable}" in WSL "$distribution"',
        cause: e,
      );
    }
  }
}
