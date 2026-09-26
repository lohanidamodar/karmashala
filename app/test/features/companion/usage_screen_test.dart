/// The phone's Usage tab: every agent account's limits as the desktop read
/// them — and, for a phone paired before usage existed, why it sees nothing.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_companion/screens.dart';
import 'package:karmashala_remote/companion.dart';
import 'package:karmashala_remote/remote.dart';

import 'companion_test_support.dart';

void main() {
  final observed = DateTime.utc(2026, 9, 19, 12);

  RemoteUsageSnapshot snapshot() => RemoteUsageSnapshot(
    observedAt: observed,
    accounts: [
      RemoteUsageAccount(
        key: 'claudeCode@windows',
        agentId: 'claudeCode',
        agentName: 'Claude Code',
        environment: 'Windows',
        email: 'me@example.com',
        readAt: observed.subtract(const Duration(minutes: 3)),
        windows: [
          RemoteUsageWindow(
            label: '5-hour',
            percent: 86,
            resetsAt: observed.add(const Duration(hours: 2, minutes: 11)),
            span: const Duration(hours: 5),
            pace: RemoteUsagePace.overPace,
            limitAt: observed.add(const Duration(minutes: 40)),
            samples: [
              RemoteUsageSample(at: observed, percent: 50),
              RemoteUsageSample(at: observed, percent: 86),
            ],
          ),
          RemoteUsageWindow(
            label: '7-day',
            percent: 12,
            resetsAt: observed.add(const Duration(days: 3, hours: 4)),
            pace: RemoteUsagePace.onPace,
          ),
        ],
      ),
      const RemoteUsageAccount(
        key: 'codex@windows',
        agentId: 'codex',
        agentName: 'Codex',
        environment: 'Windows',
        failure: 'Rate-limited by the provider; trying again in 4 min.',
      ),
    ],
  );

  Future<FakeCompanionGateway> pump(
    WidgetTester tester, {
    CapabilitySet? capabilities,
  }) async {
    final gateway = FakeCompanionGateway.paired(capabilities: capabilities)
      ..usageSnapshot = snapshot();
    await pumpPhone(
      tester,
      gateway: gateway,
      home: const Scaffold(body: UsageScreen()),
    );
    await tester.pumpAndSettle();
    return gateway;
  }

  testWidgets('every account, its windows, when they reset and the pace', (
    tester,
  ) async {
    await pump(tester);

    expect(find.text('Claude Code · Windows'), findsOneWidget);
    expect(find.text('me@example.com'), findsOneWidget);
    expect(find.text('Read 3m ago'), findsOneWidget);
    expect(find.text('86% used'), findsOneWidget);
    expect(
      find.text('Resets in 2h11m · over pace — runs out in 40m'),
      findsOneWidget,
    );
    expect(find.text('Resets in 3d 4h · within pace'), findsOneWidget);
  });

  testWidgets('an account that could not be read says why, in words', (
    tester,
  ) async {
    await pump(tester);

    expect(find.text('Codex · Windows'), findsOneWidget);
    expect(find.textContaining('Rate-limited by the provider'), findsOneWidget);
    expect(find.text('Not read yet'), findsOneWidget);
  });

  testWidgets('a phone paired before usage existed is told how to get it, '
      'and the desktop is not asked', (tester) async {
    final gateway = await pump(
      tester,
      capabilities: CapabilitySet(
        CapabilitySet.all.bits & ~Capability.viewUsage.bit,
      ),
    );

    expect(find.text('Usage was not granted to this phone'), findsOneWidget);
    expect(find.textContaining('Pair it again'), findsOneWidget);
    expect(gateway.usageReads, 0);
  });

  testWidgets('pulling down asks the desktop again', (tester) async {
    final gateway = await pump(tester);
    expect(gateway.usageReads, 1);

    await tester.fling(
      find.text('Claude Code · Windows'),
      const Offset(0, 400),
      1000,
    );
    await tester.pumpAndSettle();

    expect(gateway.usageReads, 2);
  });

  testWidgets('a refusal from the desktop is shown with a retry', (
    tester,
  ) async {
    final gateway = FakeCompanionGateway.paired()
      ..usageFailure = const GatewayException('The desktop could not say.');
    await pumpPhone(
      tester,
      gateway: gateway,
      home: const Scaffold(body: UsageScreen()),
    );
    await tester.pumpAndSettle();

    expect(find.text('The desktop could not say.'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });
}
