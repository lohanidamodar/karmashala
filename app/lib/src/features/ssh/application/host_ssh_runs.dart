import 'dart:async';

import 'package:agent_cli/process.dart';
import 'package:karmashala_core/logging.dart';
import 'package:karmashala_host/lifecycle_client.dart'
    show RunCallMessage, RunResultMessage, commandRequestFromJson;
import 'package:riverpod/riverpod.dart';

import '../../../core/process/command_runner_providers.dart';
import '../../environments/application/environment_providers.dart';
import '../../sessions/application/host_lifecycle/host_lifecycle_source.dart';
import '../../sessions/application/host_lifecycle/host_lifecycle_subscriber.dart';
import 'ssh_failure.dart';

/// **The one reach the server has through this app**: commands in an SSH
/// environment. The server finds agents, and reads and switches accounts, on
/// an SSH box too, but it has no SSH transport of its own — the box is dialled
/// with this app's connection pool, where a person is asked to trust its key
/// (`karmashala_ssh` deploys the server, so the server cannot depend on it).
/// So this offers on every link, and runs each command the server forwards
/// through this app's SSH runner, answering with what the process said.
///
/// A command may carry a file's text on stdin — an account being switched to
/// — so nothing here logs a command's content.
class HostSshRuns implements HostLinkPeer {
  HostSshRuns({required this.run, AppLogger? logger})
    : _log = logger ?? AppLogger.named('ssh.runs');

  /// Runs one command in one environment; throws to fail it.
  final Future<CommandResult> Function(
    String environmentId,
    CommandRequest request,
  )
  run;

  final AppLogger _log;
  StreamSubscription<RunCallMessage>? _calls;

  @override
  void attached(HostLifecycleFeed feed) {
    unawaited(_calls?.cancel());
    _calls = feed.runCalls.listen((call) => unawaited(_answer(feed, call)));
    feed.offerRuns();
  }

  @override
  void detached() {
    unawaited(_calls?.cancel());
    _calls = null;
  }

  Future<void> _answer(HostLifecycleFeed feed, RunCallMessage call) async {
    try {
      final result = await run(
        call.environmentId,
        commandRequestFromJson(call.command),
      );
      feed.answerRunCall(
        RunResultMessage.ran(
          call.callId,
          exitCode: result.exitCode,
          stdout: result.stdout,
          stderr: result.stderr,
        ),
      );
    } on Object catch (error) {
      _log.info('A command the server ran in ${call.environmentId} failed.');
      feed.answerRunCall(
        RunResultMessage.failed(call.callId, describeSshFailure(error)),
      );
    }
  }
}

/// Only an SSH environment's commands: the server runs the rest itself.
final hostSshRunsProvider = Provider<HostSshRuns>(
  (ref) => HostSshRuns(
    run: (environmentId, request) {
      final environment = ref
          .read(environmentsDataProvider)
          .getById(environmentId);
      if (environment == null || environment.kind != EnvironmentKind.ssh) {
        throw CommandException(
          'This app runs only SSH commands for the server, and '
          '$environmentId is not an SSH environment it knows.',
        );
      }
      return ref
          .read(commandRunnerFactoryProvider)
          .forEnvironment(environment)
          .run(request);
    },
  ),
);
