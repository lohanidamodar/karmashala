import 'dart:io';

import 'package:karmashala_acp/testing.dart';
import 'package:karmashala_session_engine/store.dart'
    show SessionMessageDao, SessionMessageRole;
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

import 'acp_fixture.dart';

/// Each agent message an ACP session writes reaches the server whole, once,
/// when its row closes — what reads a marker out of an agent's answer.
void main() {
  late AppDatabase database;
  late Directory temp;
  late RecordingHost host;

  setUp(() {
    database = AppDatabase.memory();
    database.execute('PRAGMA foreign_keys = OFF;');
    temp = Directory.systemTemp.createTempSync('acp_agent_message_test');
    host = RecordingHost();
  });

  tearDown(() {
    database.close();
    temp.deleteSync(recursive: true);
  });

  test('every closed agent row is told whole, with the agent it came from',
      () async {
    final process = FakeAcpProcess(
      FakeAcpAgent(
        turns: [
          const FakeTurn([
            FakeStep.message('Writing ', messageId: 'a1'),
            FakeStep.message('the chart.', messageId: 'a1'),
            FakeStep.message('Done: visualize{"path":"/w/c.html"}',
                messageId: 'a2'),
          ]),
        ],
      ),
    );
    final runtime = runtimeOver(
      process,
      database: database,
      workingDirectory: temp.path,
      host: host,
      agentId: 'codex-acp',
    );
    await runtime.start();
    await runtime.send('Chart it');
    await runtime.awaitTurn();

    expect(host.agentMessages, [
      ('s1', 'codex-acp', 'Writing the chart.'),
      ('s1', 'codex-acp', 'Done: visualize{"path":"/w/c.html"}'),
    ]);
    await runtime.stop();
  });

  test('the row reads as the host says, a marker taken out', () async {
    host.display = (text) =>
        text.contains('visualize{') ? text.split(' visualize{').first : null;
    final process = FakeAcpProcess(
      FakeAcpAgent(
        turns: [
          const FakeTurn([
            FakeStep.message('Done: visualize{"path":"/w/c.html"}',
                messageId: 'a1'),
          ]),
        ],
      ),
    );
    final runtime = runtimeOver(
      process,
      database: database,
      workingDirectory: temp.path,
      host: host,
      agentId: 'codex-acp',
    );
    await runtime.start();
    await runtime.send('Chart it');
    await runtime.awaitTurn();

    final agentRows = SessionMessageDao(database)
        .listAfter('s1')
        .where((r) => r.role == SessionMessageRole.agent);
    expect(agentRows.single.text, 'Done:');
    await runtime.stop();
  });
}
