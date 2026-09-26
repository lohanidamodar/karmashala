import 'package:agent_cli/usage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/agents/application/usage_history.dart';

import '../../support/fake_data_server.dart';

/// The usage history as this app sees it: recorded at the server from the
/// readings the server takes, and read back by the charts when it gains rows.
/// What is recorded, kept and pruned is the server's rule
/// (`packages/karmashala_environments`, `server/test/data`).
void main() {
  const account = 'claudeCode@env-windows';
  final t0 = DateTime.utc(2026, 9, 16, 10);

  test(
    'the history provider re-reads when the server records a reading',
    () async {
      final server = FakeDataServer();
      final container = ProviderContainer(overrides: [await server.override()]);
      addTearDown(container.dispose);
      final query = (
        account: account,
        from: t0.subtract(const Duration(hours: 5)),
      );
      final sub = container.listen(usageHistoryProvider(query), (_, _) {});
      addTearDown(sub.close);
      expect(await container.read(usageHistoryProvider(query).future), isEmpty);

      // The server's own reading, recorded and told as a change.
      server.usageRows.insert(
        UsageSample(
          accountKey: account,
          windowLabel: '5-hour',
          span: kUsageFiveHourWindow,
          percent: 20,
          recordedAt: t0,
        ),
      );
      await pumpEventQueue();
      expect(
        await container.read(usageHistoryProvider(query).future),
        hasLength(1),
      );

      // And the next one.
      server.usageRows.insert(
        UsageSample(
          accountKey: account,
          windowLabel: '7-day',
          percent: 4,
          recordedAt: t0.add(const Duration(minutes: 1)),
        ),
      );
      await pumpEventQueue();
      expect(
        await container.read(usageHistoryProvider(query).future),
        hasLength(2),
      );
    },
  );
}
