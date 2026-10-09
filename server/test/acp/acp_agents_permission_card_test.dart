import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_acp/karmashala_acp.dart'
    show PermissionSelected, ToolKind;
import 'package:karmashala_acp/testing.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

import 'acp_fixture.dart';

/// Grok (built in) and GitHub Copilot (an ACP registry row) ask permission
/// over ACP, never on a screen: a fake agent's `session/request_permission`
/// on the first turn is the open prompt every card draws — awaiting approval,
/// the ask with the agent's own options — and an answer by option id reaches
/// the agent.
void main() {
  late AppDatabase database;
  late Directory temp;
  late RecordingHost host;

  setUp(() {
    database = AppDatabase.memory();
    database.execute('PRAGMA foreign_keys = OFF;');
    temp = Directory.systemTemp.createTempSync('acp_agents_card_test');
    host = RecordingHost();
  });

  tearDown(() {
    database.close();
    temp.deleteSync(recursive: true);
  });

  for (final (agentId, spec) in [
    (AgentIds.grok, AgentRegistry.builtIn.byId(AgentIds.grok)!.acp!),
    ('github-copilot', const AcpLaunchSpec()),
  ]) {
    test('$agentId: a permission on its first turn is an open ask with its '
        'options, answered by option id', () async {
      final process = FakeAcpProcess(
        FakeAcpAgent(
          turns: [
            const FakeTurn([
              FakeStep.toolCall(
                toolCallId: 'c1',
                title: 'Run the tests',
                kind: ToolKind.execute,
                permissionOptions: fakePermissionOptions,
              ),
            ]),
          ],
        ),
      );
      final runtime = runtimeOver(
        process,
        database: database,
        workingDirectory: temp.path,
        host: host,
        agentId: agentId,
        spec: spec,
      );
      await runtime.start();
      await runtime.send('look around');
      for (
        var i = 0;
        i < 100 && !host.statuses.any((s) => s.toolAsk != null);
        i++
      ) {
        await pump();
      }

      final asking = host.statuses.lastWhere((s) => s.toolAsk != null);
      expect(asking.status, AgentActivityStatus.awaitingApproval);
      expect(asking.waiting, AgentWaitKind.approval);
      expect(asking.hasOpenPrompt, isTrue);
      expect(asking.toolAsk!.options.map((o) => o.id), [
        'allow',
        'allow-always',
        'reject',
      ]);

      final answer = await runtime.answerPermission(
        approve: true,
        toolCallId: 'c1',
        optionId: 'allow',
      );
      await runtime.awaitTurn();
      expect(answer.granted, isTrue);
      expect(
        (process.agent.permissionOutcomes.single as PermissionSelected)
            .optionId,
        'allow',
      );
      await runtime.stop();
    });
  }
}
