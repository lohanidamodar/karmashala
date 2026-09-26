import 'package:agent_cli/usage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/data/data_providers.dart';
import 'package:karmashala/src/features/agents/application/usage_history.dart';

import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import 'usage_fixtures.dart';

/// The usage history as this app sees it: fed only by readings that came off
/// the wire, recorded at the server, and read back by the charts when it
/// gains rows. What is kept and what is pruned is the server's rule
/// (`packages/karmashala_environments`, `server/test/data`).
void main() {
  const account = 'claudeCode@env-windows';
  final t0 = DateTime.utc(2026, 9, 16, 10);

  AgentUsage reading(DateTime at, {double five = 20}) => AgentUsage(
    fetchedAt: at,
    windows: [
      UsageWindow(
        label: '5-hour',
        percent: five,
        resetsAt: DateTime.utc(2026, 9, 16, 14),
        span: kUsageFiveHourWindow,
      ),
      const UsageWindow(label: 'Gemini Code Assist'),
    ],
  );

  group('fed only by fresh readings', () {
    test(
      'a reading served from memory inside the floor is not announced',
      () async {
        final clock = MovableClock(testTime);
        final service = FakeAgentUsageService(clock: clock);
        final announced = <AgentUsage>[];
        service.addReadingListener((_, usage) => announced.add(usage));
        final install = agentInstallation();

        await service.fetch(install, const []);
        clock.advance(const Duration(minutes: 1));
        await service.fetch(install, const []);
        expect(service.calls, hasLength(1));
        expect(announced, hasLength(1));

        clock.advance(usageFixtureFloor);
        await service.fetch(install, const []);
        expect(announced, hasLength(2));
      },
    );

    test('a listener that throws does not cost the reading', () async {
      final service = FakeAgentUsageService();
      service.addReadingListener((_, _) => throw StateError('disk full'));
      final usage = await service.fetch(agentInstallation(), const []);
      expect(usage.windows, isNotEmpty);
    });

    test('a failed fetch announces nothing', () async {
      final service = FakeAgentUsageService(
        failure: UsageException('nope', kind: UsageFailureKind.unreachable),
      );
      var announced = 0;
      service.addReadingListener((_, _) => announced++);
      await expectLater(
        service.fetch(agentInstallation(), const []),
        throwsA(isA<UsageException>()),
      );
      expect(announced, 0);
    });
  });

  test('a reading is recorded at the server, one sample per measured '
      'window', () async {
    final server = FakeDataServer();
    final container = ProviderContainer(overrides: [await server.override()]);
    addTearDown(container.dispose);

    final written = await container
        .read(usageHistoryRecorderProvider)
        .record(account, reading(t0));
    expect(written, 1);
    final sample = server.usageRows.latest(account, '5-hour')!;
    expect(sample.recordedAt, t0);
    expect(sample.span, kUsageFiveHourWindow);
    expect(server.usageRows.latest(account, 'Gemini Code Assist'), isNull);
    expect(server.requests, contains('usage.record'));
  });

  test('a server that is away costs the reading nothing but the row', () async {
    final server = FakeDataServer();
    final container = ProviderContainer(
      overrides: [
        dataClientProvider.overrideWithValue(
          await server.connect(wait: const Duration(milliseconds: 10)),
        ),
      ],
    );
    addTearDown(container.dispose);
    server.stop();
    expect(
      await container
          .read(usageHistoryRecorderProvider)
          .record(account, reading(t0)),
      0,
    );
  });

  test('the history provider re-reads when the history gains rows — here '
      'or at another client', () async {
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

    await container
        .read(usageHistoryRecorderProvider)
        .record(account, reading(t0));
    expect(
      await container.read(usageHistoryProvider(query).future),
      hasLength(1),
    );

    // Another client's reading, told as a change.
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
  });
}
