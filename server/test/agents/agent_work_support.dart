import 'dart:async';

import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import 'package:agent_cli/read.dart';
import 'package:agent_cli/usage.dart';

/// Test doubles for the server's agent work: a clock that moves when told,
/// ids that count, a usage service whose network half is scripted, a command
/// runner that answers from a function and a filesystem that is a set.
/// Nothing here reads a real home, Keychain or endpoint.

/// A clock at [now], moved by [advance].
class MutableClock implements Clock {
  MutableClock(this.now);

  DateTime now;

  void advance(Duration by) => now = now.add(by);

  @override
  DateTime nowUtc() => now.toUtc();
}

/// `id1`, `id2`, … — predictable, and never a real UUID.
class CountingIds implements IdGenerator {
  CountingIds([this.prefix = 'id']);

  final String prefix;
  var _next = 0;

  @override
  String newId() => '$prefix${++_next}';
}

/// An [AgentUsageService] whose network half ([fetchFresh]) is [answer]:
/// throttled and remembered exactly like the real one, and counted.
class ScriptedUsageService extends AgentUsageService {
  ScriptedUsageService({required super.clock, required this.answer})
    : super(
        storeLocator: CliStoreLocator(
          runnerFor: (id) => throw StateError('no runner for $id in a test'),
          environment: const {},
        ),
        hostIsMacOS: false,
        // No doubling spread: a rate limit's wait is the one it names.
        throttle: UsageThrottle(clock: clock, jitter: () => 0),
      );

  /// What the vendor says to the next request.
  FutureOr<AgentUsage> Function(AgentInstallation installation) answer;

  /// Every installation a real request was made for.
  final asked = <AgentInstallation>[];

  @override
  Future<AgentUsage> fetchFresh(
    AgentInstallation installation,
    List<ExecutionEnvironment> environments,
  ) async {
    asked.add(installation);
    return answer(installation);
  }
}

/// A [CommandRunner] answering from [responder], recording each request.
class ScriptedRunner implements CommandRunner {
  ScriptedRunner(this.responder, {this.environmentId = 'windows'});

  CommandResult Function(CommandRequest request) responder;

  @override
  final String environmentId;

  final requests = <CommandRequest>[];

  @override
  Future<CommandResult> run(CommandRequest request) async {
    requests.add(request);
    return responder(request);
  }

  @override
  Future<ProcessHandle> start(CommandRequest request) =>
      Future.error(CommandException('nothing is started in a test'));
}

/// A filesystem that holds [files] and nothing else.
class SetPathProbe implements PathProbe {
  SetPathProbe([Set<String> files = const {}]) : files = {...files};

  final Set<String> files;

  @override
  bool? fileExists(String path) => files.contains(path);

  @override
  bool isLink(String path) => false;

  @override
  String? linkTarget(String path) => null;
}

const ok = CommandResult(exitCode: 0, stdout: '', stderr: '');
const notFound = CommandResult(exitCode: 1, stdout: '', stderr: '');
