import 'dart:async';

import 'package:agent_cli/process.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/features/sessions/application/host_lifecycle/host_lifecycle_source.dart';
import 'package:karmashala/src/features/ssh/application/host_ssh_runs.dart';
import 'package:karmashala_host/lifecycle_client.dart'
    show RunCallMessage, RunResultMessage;

import '../../support/fake_command_runner.dart';
import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';

/// The one reach the server has through this app: an SSH environment's
/// commands, run through this app's runner and answered.
void main() {
  late StreamController<RunCallMessage> calls;
  late List<RunResultMessage> answers;
  late int offers;

  HostLifecycleFeed feed() => HostLifecycleFeed(
    snapshot: const [],
    events: const Stream.empty(),
    close: () async {},
    runCalls: calls.stream,
    offerRuns: () => offers++,
    answerRunCall: answers.add,
  );

  setUp(() {
    calls = StreamController<RunCallMessage>();
    answers = [];
    offers = 0;
  });
  tearDown(() => calls.close());

  RunCallMessage call(int id, String environmentId) => RunCallMessage(
    callId: id,
    environmentId: environmentId,
    command: {
      'executable': 'bash',
      'arguments': ['-lc', 'printf %s "\$HOME"'],
      'stdinText': 'secret-file-text',
    },
  );

  test('offers on every link and answers what it ran', () async {
    final asked = <(String, CommandRequest)>[];
    final runs = HostSshRuns(
      run: (environmentId, request) async {
        asked.add((environmentId, request));
        return const CommandResult(
          exitCode: 0,
          stdout: '/home/dev',
          stderr: '',
        );
      },
    );

    runs.attached(feed());
    calls.add(call(7, 'ssh:h1'));
    await pumpEventQueue();

    expect(offers, 1);
    expect(asked.single.$1, 'ssh:h1');
    expect(asked.single.$2.executable, 'bash');
    expect(asked.single.$2.stdinText, 'secret-file-text');
    final answer = answers.single;
    expect(answer.callId, 7);
    expect(answer.exitCode, 0);
    expect(answer.stdout, '/home/dev');
  });

  test('a command that cannot run is answered with why', () async {
    final runs = HostSshRuns(
      run: (_, _) async => throw CommandException('host key refused'),
    );
    runs.attached(feed());
    calls.add(call(3, 'ssh:h1'));
    await pumpEventQueue();

    expect(answers.single.error, contains('host key refused'));
    expect(answers.single.error, isNot(contains('secret-file-text')));
  });

  test('a lost link stops answering', () async {
    var ran = 0;
    final runs = HostSshRuns(
      run: (_, _) async {
        ran++;
        return const CommandResult(exitCode: 0, stdout: '', stderr: '');
      },
    );
    runs.attached(feed());
    runs.detached();
    calls.add(call(1, 'ssh:h1'));
    await pumpEventQueue();

    expect(ran, 0);
    expect(answers, isEmpty);
  });

  test('only an SSH environment is run for the server', () async {
    final server = FakeDataServer()
      ..environmentRows.upsert(windowsEnv())
      ..environmentRows.upsert(sshEnvFixture());
    final runner = FakeCommandRunner(
      responder: (_) =>
          const CommandResult(exitCode: 0, stdout: 'ok', stderr: ''),
    );
    final container = ProviderContainer(
      overrides: [
        await server.override(),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(fallback: runner),
        ),
      ],
    );
    addTearDown(container.dispose);
    final runs = container.read(hostSshRunsProvider);
    runs.attached(feed());

    calls.add(call(1, 'windows'));
    calls.add(call(2, sshEnvFixture().id));
    await pumpEventQueue();

    expect(answers.first.error, contains('not an SSH environment'));
    expect(answers.last.stdout, 'ok');
    expect(runner.requests, hasLength(1));
  });
}
