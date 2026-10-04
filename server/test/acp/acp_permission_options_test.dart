import 'dart:io';

import 'package:agent_cli/descriptors.dart' show AgentToolAskOption;
import 'package:karmashala_acp/karmashala_acp.dart'
    show
        PermissionOption,
        PermissionOptionKind,
        PermissionSelected,
        ToolKind;
import 'package:karmashala_acp/testing.dart';
import 'package:karmashala_agent_status/karmashala_agent_status.dart'
    show SessionPromptRefusal;
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

import 'acp_fixture.dart';

/// `session/request_permission`: every option the agent offers — allow once,
/// allow always, reject once, reject always — is carried on the ask in its
/// own words, and an answer naming one chooses exactly it.
void main() {
  late AppDatabase database;
  late Directory temp;
  late RecordingHost host;

  setUp(() {
    database = AppDatabase.memory();
    database.execute('PRAGMA foreign_keys = OFF;');
    temp = Directory.systemTemp.createTempSync('acp_permission_test');
    host = RecordingHost();
  });

  tearDown(() {
    database.close();
    temp.deleteSync(recursive: true);
  });

  const offered = [
    ...fakePermissionOptions,
    PermissionOption(
      optionId: 'reject-always',
      name: 'Never allow',
      kind: PermissionOptionKind.rejectAlways,
    ),
  ];

  Future<FakeAcpProcess> asking() async {
    final process = FakeAcpProcess(
      FakeAcpAgent(
        turns: [
          const FakeTurn([
            FakeStep.toolCall(
              toolCallId: 'c1',
              title: 'Run tests',
              kind: ToolKind.execute,
              permissionOptions: offered,
            ),
          ]),
        ],
      ),
    );
    return process;
  }

  Future<void> waitForAsk() async {
    for (var i = 0; i < 100; i++) {
      if (host.statuses.any((s) => s.toolAsk != null)) return;
      await pump();
    }
    fail('the permission was never asked');
  }

  test('the ask carries every option, in the agent\'s words and order',
      () async {
    final process = await asking();
    final runtime = runtimeOver(
      process,
      database: database,
      workingDirectory: temp.path,
      host: host,
    );
    await runtime.start();
    await runtime.send('test it');
    await waitForAsk();

    final ask = host.statuses.lastWhere((s) => s.toolAsk != null).toolAsk!;
    expect(ask.options, const [
      AgentToolAskOption(id: 'allow', name: 'Allow', kind: 'allow_once'),
      AgentToolAskOption(
        id: 'allow-always',
        name: 'Always allow',
        kind: 'allow_always',
      ),
      AgentToolAskOption(id: 'reject', name: 'Reject', kind: 'reject_once'),
      AgentToolAskOption(
        id: 'reject-always',
        name: 'Never allow',
        kind: 'reject_always',
      ),
    ]);
    runtime.cancel();
    await runtime.awaitTurn();
    await runtime.stop();
  });

  for (final (optionId, granted) in [
    ('allow-always', true),
    ('reject-always', false),
    ('reject', false),
  ]) {
    test('an answer naming "$optionId" chooses exactly it', () async {
      final process = await asking();
      final runtime = runtimeOver(
        process,
        database: database,
        workingDirectory: temp.path,
        host: host,
      );
      await runtime.start();
      await runtime.send('test it');
      await waitForAsk();

      // `approve` disagrees on purpose: the option's own kind decides.
      final answer = await runtime.answerPermission(
        approve: !granted,
        toolCallId: 'c1',
        optionId: optionId,
      );
      await runtime.awaitTurn();

      expect(answer.granted, granted);
      final chosen = offered.firstWhere((o) => o.optionId == optionId);
      expect(answer.answered, chosen.name);
      expect(answer.effect, contains('(${chosen.kind.raw})'));
      expect(
        (process.agent.permissionOutcomes.single as PermissionSelected)
            .optionId,
        optionId,
      );
      await runtime.stop();
    });
  }

  test('an option the agent did not offer is refused, and the ask stays',
      () async {
    final process = await asking();
    final runtime = runtimeOver(
      process,
      database: database,
      workingDirectory: temp.path,
      host: host,
    );
    await runtime.start();
    await runtime.send('test it');
    await waitForAsk();

    await expectLater(
      runtime.answerPermission(approve: true, optionId: 'sudo'),
      throwsA(isA<SessionPromptRefusal>()),
    );
    expect(runtime.hasOpenPermission, isTrue);

    final answer = await runtime.answerPermission(approve: true);
    expect(answer.answered, 'Allow', reason: 'no option: the first allow');
    await runtime.awaitTurn();
    expect(
      process.agent.permissionOutcomes.single,
      isA<PermissionSelected>(),
    );
    await runtime.stop();
  });
}
