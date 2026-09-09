import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';

import 'ssh_connection.dart';
import 'ssh_connection_pool.dart';
import 'ssh_process_handle.dart';
import 'package:agent_cli/process.dart';

/// Renders [request] as the one command string SSH will run.
///
/// Pure and side-effect free so the quoting can be unit-tested without a server.
/// A working directory becomes a `cd` guarded by `&&` — if the directory is
/// missing the command must not silently run somewhere else — and `exec` hands
/// the channel straight to the process so its exit status is the one reported.
String buildRemoteCommandLine(CommandRequest request) {
  final command = [
    posixQuote(request.executable),
    ...request.arguments.map(posixQuote),
  ].join(' ');
  final cwd = request.workingDirectory;
  if (cwd == null) return 'exec $command';
  return 'cd ${posixQuote(cwd.path)} && exec $command';
}

/// Exit code reported when the remote process was killed by a signal. Shells use
/// 128+signal; the SSH exit-signal message names the signal rather than
/// numbering it, so the base alone is used and the name goes to stderr.
const int kSshSignalExitCode = 128;

/// Runs commands on a remote host over SSH.
///
/// The third [CommandRunner] beside `LocalCommandRunner` and
/// `WslCommandRunner`, and the reason agent discovery, Git and everything else
/// can target a remote machine without knowing SSH exists: they build the same
/// [CommandRequest] and this translates it for the wire.
///
/// The connection is owned by [connection] and shared across every command, so
/// the per-command cost is one channel open rather than a TCP connect and a key
/// exchange. When that connection is down, [run] and [start] **throw** — a lost
/// link is never reported as an empty successful command.
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
      result = await connection.runOnChannel(
        (client) => client.runWithResult(line),
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

/// The factory Karmashala composes: `agent_cli`'s local and WSL cases, plus the
/// one this app adds.
///
/// `agent_cli` runs commands on this machine and inside its WSL distributions
/// and stops there — reaching another machine means a connection, a key and
/// somewhere to keep both, which is this app's business and not a coding CLI's
/// (docs/PACKAGE_SPLIT.md §3). Overriding [unsupported] rather than
/// [forEnvironment] is what keeps the local and WSL cases from drifting between
/// the two copies.
///
/// [sshConnections] supplies the shared connection an SSH runner needs. It is a
/// callback rather than a value so that composing the factory — which the whole
/// app does — never builds a connection pool, and therefore never touches the
/// database, unless a remote environment is actually asked for. It is optional
/// because most of the app is composed without one; asking for an SSH runner
/// without it is a wiring bug and fails loudly rather than connecting something
/// unconfigured.
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
