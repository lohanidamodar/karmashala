import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import 'ssh_connection.dart';
import 'ssh_connection_pool.dart';
import 'ssh_process_handle.dart';
import 'package:agent_cli/process.dart';

/// Renders [request] as the one command string SSH will run. A working
/// directory becomes a `cd` guarded by `&&`, so a missing one runs nothing.
String buildRemoteCommandLine(CommandRequest request) {
  final command = [
    ...posixEnvironmentPrefix(request),
    request.executable,
    ...request.arguments,
  ].map(posixQuote).join(' ');
  final cwd = request.workingDirectory;
  if (cwd == null) return 'exec $command';
  return 'cd ${posixQuote(cwd.path)} && exec $command';
}

/// `runWithResult`, but with [stdinText] written to the remote process's stdin
/// and the channel's EOF sent after it.
///
/// `runWithResult` takes no stdin, and [SshCommandRunner.run] used to drop
/// [CommandRequest.stdinText] on the floor — so a command that read its input
/// from stdin got none on SSH and nothing said so. Stdin is where a payload
/// that must not be on a command line travels (an OAuth token bundle, which an
/// argument would put in the remote host's process list), so it has to arrive.
Future<SSHRunResult> runWithStdin(
  SSHClient client,
  String command,
  String stdinText,
) async {
  final session = await client.execute(command);
  final stdout = BytesBuilder(copy: false);
  final stderr = BytesBuilder(copy: false);
  final stdoutDone = Completer<void>();
  final stderrDone = Completer<void>();
  final stdoutSub = session.stdout.listen(
    stdout.add,
    onDone: stdoutDone.complete,
    onError: stdoutDone.completeError,
    cancelOnError: true,
  );
  final stderrSub = session.stderr.listen(
    stderr.add,
    onDone: stderrDone.complete,
    onError: stderrDone.completeError,
    cancelOnError: true,
  );
  try {
    session.write(Uint8List.fromList(utf8.encode(stdinText)));
    await session.stdin.close();
    await Future.wait([stdoutDone.future, stderrDone.future], eagerError: true);
    await session.done;
  } catch (_) {
    await stdoutSub.cancel();
    await stderrSub.cancel();
    session.close();
    rethrow;
  }
  final out = stdout.takeBytes();
  return SSHRunResult(
    output: out,
    stdout: out,
    stderr: stderr.takeBytes(),
    exitCode: session.exitCode,
    exitSignal: session.exitSignal,
  );
}

/// Exit code for a remote process killed by a signal: shells use 128+signal,
/// but SSH names the signal, so the base is used and the name goes to stderr.
const int kSshSignalExitCode = 128;

/// Runs commands on a remote host over SSH, on one shared connection. When it
/// is down, [run] and [start] **throw** — never an empty successful command.
class SshCommandRunner implements CommandRunner {
  SshCommandRunner({required this.environmentId, required this.connection});

  @override
  final String environmentId;

  final SshConnection connection;

  @override
  Future<CommandResult> run(CommandRequest request) async {
    final line = buildRemoteCommandLine(request);
    final SSHRunResult result;
    try {
      // Through the connection's channel limiter: a fan-out of probes queues
      // rather than tripping the server's session limit.
      final stdinText = request.stdinText;
      result = await connection.runOnChannel(
        (client) => stdinText == null
            ? client.runWithResult(line)
            : runWithStdin(client, line, stdinText),
      );
    } on SshConnectionException catch (e) {
      throw _unreachable(request, 'run', e);
    } on SSHChannelOpenError catch (e) {
      throw CommandException(
        '${connection.host.address} refused another channel for '
        '"${request.executable}"; its session limit (OpenSSH MaxSessions) is '
        'reached',
        cause: e,
      );
    } on SSHError catch (e) {
      throw CommandException(
        'Failed to run "${request.executable}" on ${connection.host.address}',
        cause: e,
      );
    }

    final stdout = _decode(result.stdout);
    final stderr = _decode(result.stderr);
    final exitCode = result.exitCode;
    if (exitCode != null) {
      return CommandResult(exitCode: exitCode, stdout: stdout, stderr: stderr);
    }

    final signal = result.exitSignal;
    if (signal != null) {
      return CommandResult(
        exitCode: kSshSignalExitCode,
        stdout: stdout,
        stderr: '$stderr\nterminated by signal ${signal.signalName}',
      );
    }

    // No exit status and no signal: the channel died under us. Reporting exit
    // code 0 with whatever output arrived first would be a lie.
    throw CommandException(
      'The connection to ${connection.host.address} was lost before '
      '"${request.executable}" reported an exit status',
    );
  }

  @override
  Future<ProcessHandle> start(CommandRequest request) async {
    final client = await _client(request, verb: 'start');
    try {
      return SshProcessHandle(
        await client.execute(buildRemoteCommandLine(request)),
      );
    } on SSHError catch (e) {
      throw CommandException(
        'Failed to start "${request.executable}" on ${connection.host.address}',
        cause: e,
      );
    }
  }

  Future<SSHClient> _client(
    CommandRequest request, {
    required String verb,
  }) async {
    try {
      return await connection.client();
    } on SshConnectionException catch (e) {
      throw _unreachable(request, verb, e);
    }
  }

  CommandException _unreachable(
    CommandRequest request,
    String verb,
    SshConnectionException e,
  ) => CommandException(
    'Cannot $verb "${request.executable}" on ${connection.host.address}: '
    '${e.message}',
    cause: e.cause ?? e,
  );

  static String _decode(List<int> bytes) =>
      const Utf8Decoder(allowMalformed: true).convert(bytes);
}

/// The factory Karmashala composes: `agent_cli`'s local and WSL cases plus this
/// one. [sshConnections] is a callback, so composing never builds a pool.
class SshCommandRunnerFactory extends CommandRunnerFactory {
  const SshCommandRunnerFactory({this.sshConnections});

  final SshConnectionPool Function()? sshConnections;

  @override
  bool get canReachRemote => sshConnections != null;

  @override
  CommandRunner unsupported(ExecutionEnvironment environment) {
    final pool = sshConnections?.call();
    if (pool == null) {
      throw StateError(
        'No SSH connection pool is configured; cannot run commands in '
        '${environment.id}',
      );
    }
    return SshCommandRunner(
      environmentId: environment.id,
      connection: pool.forEnvironment(environment),
    );
  }
}
