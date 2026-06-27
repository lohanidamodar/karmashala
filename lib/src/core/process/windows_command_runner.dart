import 'dart:io';

import '../../features/environments/domain/local_environment.dart';
import 'command_runner.dart';
import 'io_process_handle.dart';
import 'process_handle.dart';

/// Runs commands on the **Windows host** via `dart:io` `Process`.
///
/// This is the only place (besides [WslCommandRunner]) that touches `Process`;
/// features go through the [CommandRunner] interface.
class WindowsCommandRunner implements CommandRunner {
  const WindowsCommandRunner();

  @override
  String get environmentId => localWindowsEnvironmentId;

  @override
  Future<CommandResult> run(CommandRequest request) async {
    try {
      final result = await Process.run(
        request.executable,
        request.arguments,
        workingDirectory: request.workingDirectory?.path,
        // wsl.exe and several Windows tools emit UTF-16; decode leniently and
        // let callers strip control characters as needed (see Loop 3 parser).
        stdoutEncoding: const SystemEncoding(),
        stderrEncoding: const SystemEncoding(),
      );
      return CommandResult(
        exitCode: result.exitCode,
        stdout: result.stdout as String,
        stderr: result.stderr as String,
      );
    } on ProcessException catch (e) {
      throw CommandException(
        'Failed to run "${request.executable}" on Windows',
        cause: e,
      );
    }
  }

  @override
  Future<ProcessHandle> start(CommandRequest request) async {
    try {
      final process = await Process.start(
        request.executable,
        request.arguments,
        workingDirectory: request.workingDirectory?.path,
        runInShell: request.runInShell,
      );
      return IoProcessHandle(process);
    } on ProcessException catch (e) {
      throw CommandException(
        'Failed to start "${request.executable}" on Windows',
        cause: e,
      );
    }
  }
}
