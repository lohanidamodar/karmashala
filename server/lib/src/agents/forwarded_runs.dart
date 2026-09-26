import 'dart:async';

import 'package:agent_cli/process.dart';

import '../protocol/messages.dart';

/// What a forwarded command fails with when no app has offered to run them.
const String kRunsAppNotRunning =
    'SSH is reached through the Karmashala app, and it is not running';

/// The commands the server runs through the app: the one connection that
/// last offered ([RunOfferMessage]) and the calls in flight. The server has
/// no SSH transport of its own — `karmashala_ssh`, which dials a box and
/// asks a person to trust its key, deploys this server and so cannot be one
/// of its dependencies — so an SSH environment's commands take this path.
class ForwardedRuns {
  _RunsLink? _app;
  final _pending = <int, _PendingRun>{};
  var _lastCallId = 0;

  bool get connected => _app != null;

  /// [owner] runs them from now on; frames to it go through [send].
  void adopt(Object owner, void Function(HostMessage) send) {
    final previous = _app;
    _app = _RunsLink(owner, send);
    if (previous != null && !identical(previous.owner, owner)) {
      _failCallsOf(previous.owner, 'the Karmashala app was replaced');
    }
  }

  /// [owner]'s answer to one call; ignored when nothing waits for it.
  void answer(Object owner, RunResultMessage result) {
    final pending = _pending[result.callId];
    if (pending == null || !identical(pending.owner, owner)) return;
    _pending.remove(result.callId);
    final error = result.error;
    if (error != null) {
      pending.done.completeError(CommandException(error));
    } else {
      pending.done.complete(
        CommandResult(
          exitCode: result.exitCode!,
          stdout: result.stdout ?? '',
          stderr: result.stderr ?? '',
        ),
      );
    }
  }

  /// [owner] hung up: its calls fail and nothing more goes to it.
  void detach(Object owner) {
    if (identical(_app?.owner, owner)) _app = null;
    _failCallsOf(owner, 'the Karmashala app closed before it answered');
  }

  /// Runs [request] in [environmentId] through the app. Throws
  /// [CommandException] when no app is there, or it could not run it.
  Future<CommandResult> run(String environmentId, CommandRequest request) {
    final app = _app;
    if (app == null) {
      return Future.error(CommandException(kRunsAppNotRunning));
    }
    final callId = ++_lastCallId;
    final done = Completer<CommandResult>();
    _pending[callId] = _PendingRun(app.owner, done);
    app.send(
      RunCallMessage(
        callId: callId,
        environmentId: environmentId,
        command: commandRequestToJson(request),
      ),
    );
    final timeout = request.timeout;
    if (timeout == null) return done.future;
    // The app enforces the command's own timeout; this bounds a link that
    // stops answering.
    return done.future.timeout(
      timeout + const Duration(seconds: 10),
      onTimeout: () {
        _pending.remove(callId);
        throw CommandException('the Karmashala app did not answer in time');
      },
    );
  }

  /// Fails every call in flight: the server is stopping.
  void close() {
    for (final pending in _pending.values) {
      pending.done.completeError(CommandException('the server is stopping'));
    }
    _pending.clear();
    _app = null;
  }

  void _failCallsOf(Object owner, String why) {
    for (final entry in _pending.entries.toList()) {
      if (!identical(entry.value.owner, owner)) continue;
      _pending.remove(entry.key);
      entry.value.done.completeError(CommandException(why));
    }
  }
}

/// A [CommandRunner] for one environment whose commands [runs] forwards to
/// the app. Only [run]: nothing the server does in an SSH environment needs
/// a long-lived process.
class ForwardedCommandRunner implements CommandRunner {
  ForwardedCommandRunner(this.environmentId, this.runs);

  @override
  final String environmentId;

  final ForwardedRuns runs;

  @override
  Future<CommandResult> run(CommandRequest request) =>
      runs.run(environmentId, request);

  @override
  Future<ProcessHandle> start(CommandRequest request) => Future.error(
    CommandException('the server cannot hold a process open in $environmentId'),
  );
}

/// [request] as a [RunCallMessage] carries it.
Map<String, Object?> commandRequestToJson(CommandRequest request) => {
  'executable': request.executable,
  'arguments': request.arguments,
  if (request.workingDirectory != null)
    'workingDirectory': {
      'environmentId': request.workingDirectory!.environmentId,
      'path': request.workingDirectory!.path,
    },
  if (request.runInShell) 'runInShell': true,
  'stdinText': ?request.stdinText,
  if (request.timeout != null) 'timeoutMs': request.timeout!.inMilliseconds,
  if (request.environment.isNotEmpty) 'environment': request.environment,
  if (request.removedEnvironment.isNotEmpty)
    'removedEnvironment': [...request.removedEnvironment],
};

/// The [CommandRequest] a [RunCallMessage] carries. Throws [FormatException].
CommandRequest commandRequestFromJson(Map<String, Object?> json) {
  final executable = json['executable'];
  final arguments = json['arguments'] ?? const <Object?>[];
  if (executable is! String || arguments is! List) {
    throw const FormatException('not a command');
  }
  final directory = json['workingDirectory'];
  final timeout = json['timeoutMs'];
  final environment = json['environment'];
  final removed = json['removedEnvironment'];
  return CommandRequest(
    executable: executable,
    arguments: [for (final a in arguments) a as String],
    workingDirectory: directory is Map
        ? EnvironmentPath(
            environmentId: directory['environmentId'] as String,
            path: directory['path'] as String,
          )
        : null,
    runInShell: json['runInShell'] == true,
    stdinText: json['stdinText'] as String?,
    timeout: timeout is int ? Duration(milliseconds: timeout) : null,
    environment: environment is Map
        ? environment.cast<String, String>()
        : const {},
    removedEnvironment: removed is List
        ? {for (final name in removed) name as String}
        : const {},
  );
}

class _RunsLink {
  _RunsLink(this.owner, this.send);
  final Object owner;
  final void Function(HostMessage) send;
}

class _PendingRun {
  _PendingRun(this.owner, this.done);
  final Object owner;
  final Completer<CommandResult> done;
}

/// Where the server runs a command: here, in a WSL distribution through
/// `wsl.exe`, or on an SSH box through the app ([ForwardedRuns]).
class ServerRunnerFactory extends CommandRunnerFactory {
  const ServerRunnerFactory(this.runs);

  final ForwardedRuns runs;

  @override
  bool get canReachRemote => true;

  @override
  CommandRunner unsupported(ExecutionEnvironment environment) =>
      ForwardedCommandRunner(environment.id, runs);
}
