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
    this.environment = const {},
  });
  final String executable;
  final List<String> arguments;

  /// The request's own; killing `wsl.exe` ends the command it relays.
  final Duration? timeout;

  /// Set on the `wsl.exe` process itself: the request's variables, and the
  /// `WSLENV` that carries them across into the distribution.
  final Map<String, String> environment;

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
    environment: environment,
  );
}

/// A POSIX variable name: the only kind `WSLENV` and `env -u` can carry.
final _variableName = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

/// [inherited] (this process's own `WSLENV`) with [names] forwarded as `/u`
/// — Win32 to WSL only, the value untranslated — replacing any entry of the
/// same name.
String _wslEnvFor(Iterable<String> names, String? inherited) {
  final ours = names.toSet();
  bool isOurs(String entry) {
    final name = entry.split('/').first.toUpperCase();
    return ours.any((n) => n.toUpperCase() == name);
  }

  return [
    for (final entry in (inherited ?? '').split(':'))
      if (entry.isNotEmpty && !isOurs(entry)) entry,
    for (final name in ours) '$name/u',
  ].join(':');
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
///
/// The request's variables are set on `wsl.exe` and named in `WSLENV`
/// ([inheritedWslEnv] is this process's own, kept), never written as
/// `NAME=value` words: under `--` the user's shell would re-parse a value
/// holding `$`, `;`, a quote or a space, and a key on the command line is in
/// every process listing. A removal is `env -u NAME` inside. A name that is
/// not a POSIX variable name throws [CommandException].
WslInvocation buildWslInvocation(
  String distribution,
  CommandRequest request, {
  bool exec = false,
  String? inheritedWslEnv,
}) {
  for (final name in [
    ...request.environment.keys,
    ...request.removedEnvironment,
  ]) {
    if (!_variableName.hasMatch(name)) {
      throw CommandException(
        '"$name" is not a variable name a WSL command can be given',
      );
    }
  }
  final args = <String>['-d', distribution];
  final cwd = request.workingDirectory;
  if (cwd != null) {
    args
      ..add('--cd')
      ..add(cwd.path);
  }
  // A variable the request also sets is set, so it is not removed after.
  final removed = [
    for (final name in request.removedEnvironment)
      if (!request.environment.containsKey(name)) name,
  ];
  args
    ..add(exec ? '--exec' : '--')
    ..addAll([
      if (removed.isNotEmpty) 'env',
      for (final name in removed) ...['-u', name],
    ])
    ..add(request.executable)
    ..addAll(request.arguments);
  return WslInvocation(
    'wsl.exe',
    args,
    stdinText: request.stdinText,
    timeout: request.timeout,
    environment: request.environment.isEmpty
        ? const {}
        : {
            ...request.environment,
            'WSLENV': _wslEnvFor(request.environment.keys, inheritedWslEnv),
          },
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
  /// which expands `$…` and breaks on quotes. Variables reach it unchanged in
  /// both modes; see [buildWslInvocation].
  final bool exec;

  WslInvocation _invocationFor(CommandRequest request) => buildWslInvocation(
    distribution,
    request,
    exec: exec,
    inheritedWslEnv: Platform.environment['WSLENV'],
  );

  @override
  Future<CommandResult> run(CommandRequest request) async {
    final invocation = _invocationFor(request);
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
    final invocation = _invocationFor(request);
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
