import 'dart:io';

import './command_runner.dart';
import './io_process_handle.dart';
import './process_handle.dart';
import './process_spawn.dart';
import './process_spawner.dart';

/// A `wsl.exe` invocation: the Windows-side executable and arguments that run a
/// command inside a specific WSL distribution.
class WslInvocation {
  const WslInvocation(
    this.executable,
    this.arguments, {
    this.stdinText,
    this.timeout,
  });
  final String executable;
  final List<String> arguments;

  /// Set only by an `exec` invocation; see [WslCommandRunner.exec].
  final Duration? timeout;

  /// Written to `wsl.exe`'s stdin, which forwards it to the command, then
  /// closed so the command sees end-of-file. Null closes stdin at once.
  final String? stdinText;

  /// The invocation as a request for the **Windows host** to create.
  ///
  /// The distribution's working directory is already an argument (`--cd`), so
  /// there is no `EnvironmentPath` left to carry: what remains is a plain
  /// `wsl.exe` command line, which is precisely what makes it something a
  /// spawner can be handed. No `runInShell` — see [buildWslInvocation].
  CommandRequest get hostRequest => CommandRequest(
    executable: executable,
    arguments: arguments,
    stdinText: stdinText,
    timeout: timeout,
  );
}

/// Builds the `wsl.exe` command line to run [request] inside [distribution].
///
/// Pure and side-effect free so it can be unit-tested without a real WSL. Uses
/// `--cd` to set the working directory (a WSL path) and `--` to separate WSL's
/// own flags from the target command and its arguments.
///
/// `request.runInShell` is deliberately not carried over. It exists to let the
/// *Windows* shell resolve an app-execution alias, and the executable started
/// here is always `wsl.exe`; the request's own executable is an argument that
/// the distribution resolves on its own PATH. Wrapping this in `cmd.exe` would
/// change which machine did the resolving, not fix anything.
///
/// [exec] uses `--exec` instead of `--`: the command is started directly, not
/// handed to the user's shell as one line to re-parse.
WslInvocation buildWslInvocation(
  String distribution,
  CommandRequest request, {
  bool exec = false,
}) {
  final args = <String>['-d', distribution];
  final cwd = request.workingDirectory;
  if (cwd != null) {
    args
      ..add('--cd')
      ..add(cwd.path);
  }
  args
    ..add(exec ? '--exec' : '--')
    ..add(request.executable)
    ..addAll(request.arguments);
  return WslInvocation(
    'wsl.exe',
    args,
    stdinText: request.stdinText,
    timeout: exec ? request.timeout : null,
  );
}

/// Runs commands inside a named WSL distribution by invoking `wsl.exe` on the
/// Windows host.
///
/// **The expensive runner, and the reason the spawner exists.** Measured on the
/// owner's machine, spawning `wsl.exe -d <distro> -- true` — a command that does
/// nothing — cost 208, 439 and 328 ms across three runs, against ~90 ms for
/// `git.exe`. Expanding one project fires about thirty probes; on this runner
/// that used to be seconds of an unpainted interface, because the creation is
/// charged to the isolate that asks. [run] now asks from a worker isolate.
///
/// It is still selected by `EnvironmentKind.wsl` and never by a platform check,
/// so a macOS or Linux build cannot reach it — `EnvironmentKind.wsl` rows only
/// exist where the host is Windows. Nothing about routing the creation through
/// a spawner changes that: the spawner is chosen by neither kind nor platform,
/// because a spawn on the UI isolate is a spawn on the UI isolate everywhere.
class WslCommandRunner implements CommandRunner {
  /// [spawner] is where this runner's processes are created; `null` means the
  /// app-wide [sharedProcessSpawner].
  const WslCommandRunner({
    required this.environmentId,
    required this.distribution,
    this.spawner,
    this.exec = false,
  });

  @override
  final String environmentId;

  /// The WSL distribution name (e.g. `Ubuntu`).
  final String distribution;

  final ProcessSpawner? spawner;

  /// Start commands with `wsl.exe --exec`, so an argument reaches the command
  /// byte for byte. The default `--` passes the line through the user's shell,
  /// which expands `$…` and breaks on quotes, and it never carried a timeout;
  /// this mode is new, so it honours the request's.
  final bool exec;

  @override
  Future<CommandResult> run(CommandRequest request) async {
    final invocation = buildWslInvocation(distribution, request, exec: exec);
    try {
      return await (spawner ?? sharedProcessSpawner).run(
        invocation.hostRequest,
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
    final invocation = buildWslInvocation(distribution, request, exec: exec);
    try {
      return IoProcessHandle(await spawnStreaming(invocation.hostRequest));
    } on ProcessException catch (e) {
      throw CommandException(
        'Failed to start "${request.executable}" in WSL "$distribution"',
        cause: e,
      );
    }
  }
}
