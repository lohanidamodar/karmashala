import 'dart:io';

import 'package:karmashala_acp/karmashala_acp.dart' show UsageCost;
import 'package:karmashala_acp/testing.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show SessionUsageChanged;
import 'package:karmashala_host/src/acp/acp_session_modes.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

import 'acp_fixture.dart';

/// An agent's `usage_update`s: the latest is kept and told at once, the last
/// of a turn becomes the turn's entry, and a late client is greeted with it.
void main() {
  late AppDatabase database;
  late Directory temp;
  late RecordingHost host;

  setUp(() {
    database = AppDatabase.memory();
    database.execute('PRAGMA foreign_keys = OFF;');
    temp = Directory.systemTemp.createTempSync('acp_usage_test');
    host = RecordingHost();
  });

  tearDown(() {
    database.close();
    temp.deleteSync(recursive: true);
  });

  test(
    'the latest report is kept, told, and the turn ends with its last',
    () async {
      final process = FakeAcpProcess(
        FakeAcpAgent(
          turns: [
            const FakeTurn([
              FakeStep.usage(used: 1200, size: 200000),
              FakeStep.message('Hello'),
              FakeStep.usage(
                used: 1800,
                size: 200000,
                cost: UsageCost(amount: 0.02, currency: 'USD'),
              ),
            ]),
            const FakeTurn([FakeStep.usage(used: 2600, size: 200000)]),
          ],
        ),
      );
      final runtime = runtimeOver(
        process,
        database: database,
        workingDirectory: temp.path,
        host: host,
      );
      await runtime.start();
      expect(runtime.reportedUsage, isNull);

      await runtime.send('hi');
      await runtime.awaitTurn();
      expect(host.usage.map((u) => u.contextUsed), [1200, 1800]);
      expect(host.usage.last.costAmount, 0.02);
      expect(host.usage.last.costCurrency, 'USD');
      expect(runtime.reportedUsage!.contextUsed, 1800);

      var kept = SessionUsageDao(database).getBySession('s1')!;
      expect(kept.contextUsed, 1800);
      expect(kept.contextSize, 200000);
      expect(kept.costAmount, 0.02);
      expect(kept.turns.map((t) => t.contextUsed), [1800]);

      await runtime.send('more');
      await runtime.awaitTurn();
      kept = SessionUsageDao(database).getBySession('s1')!;
      expect(kept.turns.map((t) => t.contextUsed), [1800, 2600]);
      // A turn without a cost keeps the last one the agent gave.
      expect(kept.costAmount, 0.02);
      await runtime.stop();
    },
  );

  test('a turn with no report adds no entry', () async {
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
    );
    await runtime.start();
    await runtime.send('hi');
    await runtime.awaitTurn();
    expect(host.usage, isEmpty);
    expect(SessionUsageDao(database).getBySession('s1'), isNull);
    await runtime.stop();
  });

  test('a late client is greeted with the latest report', () async {
    final process = FakeAcpProcess(
      FakeAcpAgent(
        turns: [
          const FakeTurn([FakeStep.usage(used: 500, size: 1000)]),
        ],
      ),
    );
    final runtime = runtimeOver(
      process,
      database: database,
      workingDirectory: temp.path,
      host: host,
    );
    await runtime.start();
    await runtime.send('hi');
    await runtime.awaitTurn();
    final changer = AcpSessionModes(
      runtimeOf: (_) => runtime,
      running: () => [runtime],
    );
    final usage = changer.greeting().whereType<SessionUsageChanged>().single;
    expect(usage.sessionId, 's1');
    expect(usage.contextUsed, 500);
    expect(usage.contextSize, 1000);
    await runtime.stop();
  });
}
