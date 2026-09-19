import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/usage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/application/agent_usage_providers.dart';
import 'package:karmashala/src/features/agents/application/usage_history.dart';
import 'package:karmashala/src/features/agents/domain/usage_sample.dart';
import 'package:karmashala/src/features/remote/application/remote_usage_bindings.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_store/database.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../agents/usage_fixtures.dart';

void main() {
  late AppDatabase db;
  late FakeAgentUsageService service;

  ProviderContainer containerFor() {
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        agentUsageServiceProvider.overrideWithValue(service),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  setUp(() {
    db = seedUsageDatabase();
    service = FakeAgentUsageService();
  });
  tearDown(() => db.close());

  Future<RemoteUsageSnapshot> read(ProviderContainer container) => container
      .read(Provider<Future<RemoteUsageSnapshot> Function()>(
        (ref) => () => remoteUsageSnapshot(ref),
      ))();

  test('one account per agent and machine, with its windows and pace', () async {
    service.answer = usageSnapshot(percent: 90);
    final snapshot = await read(containerFor());

    final account = snapshot.accounts.single;
    expect(account.agentId, AgentIds.claudeCode);
    expect(account.agentName, 'Claude Code');
    expect(account.email, 'owner@example.com');
    expect(account.readAt, testTime);
    expect(account.windows.map((w) => w.label), ['5-hour', '7-day']);
    final five = account.windows.first;
    expect(five.percent, 90);
    expect(five.span, kUsageFiveHourWindow);
    // 90% used with 2h11m of 5h left: far over an even rate.
    expect(five.pace, RemoteUsagePace.overPace);
    expect(five.limitAt, isNotNull);
    expect(snapshot.observedAt, testTime);
  });

  test('a refused reading says why, and invents no windows', () async {
    service.failure = UsageException('Signed out of Claude Code.');

    final account = (await read(containerFor())).accounts.single;

    expect(account.failure, 'Signed out of Claude Code.');
    expect(account.windows, isEmpty);
    expect(account.readAt, isNull);
  });

  test('the last day of history rides along, thinned', () async {
    final container = containerFor();
    final dao = container.read(usageSampleDaoProvider);
    for (var i = 0; i < 100; i++) {
      dao.insert(
        UsageSample(
          accountKey: usageAccountKeyOf(AgentIds.claudeCode, 'windows'),
          windowLabel: '5-hour',
          percent: i.toDouble() / 2,
          recordedAt: testTime.subtract(Duration(minutes: 10 * (100 - i))),
        ),
      );
    }

    final five = (await read(container)).accounts.single.windows.first;

    expect(five.samples.length, kRemoteUsageSamples);
    expect(five.samples.last.percent, 49.5, reason: 'the newest point is kept');
  });

  test('thinning keeps the first and last point', () {
    final samples = [
      for (var i = 0; i < 200; i++)
        RemoteUsageSample(at: testTime.add(Duration(minutes: i)), percent: i * 1.0),
    ];
    final thinned = thinUsageSamples(samples);
    expect(thinned.length, kRemoteUsageSamples);
    expect(thinned.first.percent, 0);
    expect(thinned.last.percent, 199);
  });
}
