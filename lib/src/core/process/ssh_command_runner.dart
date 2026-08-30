import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';

import '../../features/ssh/data/ssh_connection.dart';
import '../../features/ssh/data/ssh_process_handle.dart';
import 'command_runner.dart';
import 'process_handle.dart';

/// Quotes [value] for a POSIX shell.
///
/// SSH does not take an argument vector — the server is handed one string that
/// the login shell parses — so quoting is the boundary that keeps a repository
/// path containing `;` or `$(...)` from becoming remote code execution. Single
/// quotes suppress every expansion; the only character they cannot contain is a
/// single quote, which is spliced back in as `'\''`.
String posixQuote(String value) => "'${value.replaceAll("'", r"'\''")}'";

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
/// The third [CommandRunner] beside `WindowsCommandRunner` and
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
