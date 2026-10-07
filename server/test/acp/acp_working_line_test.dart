import 'dart:io';

import 'package:agent_cli/descriptors.dart' show AgentActivityStatus;
import 'package:karmashala_acp/testing.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

import 'acp_fixture.dart';

/// A chat session's working line counts from the prompt, carried on the
/// status the runtime already publishes; a finished turn carries none.
void main() {
  late AppDatabase database;
  late Directory temp;
  late RecordingHost host;

  setUp(() {
    database = AppDatabase.memory();
    database.execute('PRAGMA foreign_keys = OFF;');
    temp = Directory.systemTemp.createTempSync('acp_working_line_test');
    host = RecordingHost();
  });

  tearDown(() {
    database.close();
    temp.deleteSync(recursive: true);
  });

  test('working counts from the prompt; idle carries nothing', () async {
    var now = DateTime.utc(2026, 10, 7, 9);
    final process = FakeAcpProcess(
      FakeAcpAgent(
        turns: [
          const FakeTurn([FakeStep.message('Hello')]),
        ],
      ),
    );
    final runtime = runtimeOver(
      process,
      database: database,
      workingDirectory: temp.path,
      host: host,
      now: () => now,
    );
    await runtime.start();
    final prompted = now;
    await runtime.send('hi');
    now = now.add(const Duration(seconds: 5));
    await runtime.awaitTurn();

    final working = host.statuses.firstWhere(
      (report) => report.status == AgentActivityStatus.working,
    );
    expect(working.working?.since, prompted);
    expect(working.working?.word, isNull, reason: 'ACP sends no word');
    final last = host.statuses.last;
    expect(last.status, AgentActivityStatus.idle);
    expect(last.working, isNull);
    await runtime.stop();
  });
}
