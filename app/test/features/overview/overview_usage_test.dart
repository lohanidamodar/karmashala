import 'dart:io';

import 'package:agent_cli/usage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/overview/application/overview_providers.dart';
import 'package:karmashala/src/features/overview/application/overview_usage.dart';
import 'package:karmashala/src/features/overview/presentation/overview_card_parts.dart';
import 'package:karmashala/src/features/sessions/application/session_usage_providers.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

import 'mission_fixture.dart';

/// **Usage per session, where reported**: tokens as the session's file
/// recorded them, spend as the agent reported it, "not recorded" otherwise,
/// and a warning when the account's own reading is near a limit.
void main() {
  final now = MissionFixture.now;

  group('in words', () {
    test('tokens and reported spend; nothing reported says so', () {
      expect(
        overviewUsageText(
          const OverviewUsage(
            tokens: 1234567,
            cost: (amount: 0.42, currency: 'USD'),
            read: true,
          ),
        ),
        r'1.2M tokens · $0.42',
      );
      expect(
        overviewUsageText(
          const OverviewUsage(cost: (amount: 1.5, currency: 'EUR'), read: true),
        ),
        'tokens not recorded · 1.50 EUR',
      );
      expect(
        overviewUsageText(const OverviewUsage(read: true)),
        'Usage not recorded',
      );
    });

    test('a limit is the account\'s reading, never a projection', () {
      expect(
        overviewLimitText(
          OverviewLimit(
            label: '5h',
            percent: 92.4,
            resetsAt: now.add(const Duration(minutes: 12)),
          ),
          now,
        ),
        '5h limit 92% · resets in 12m',
      );
      expect(
        overviewLimitText(
          const OverviewLimit(label: 'Weekly', percent: 85),
          now,
        ),
        'Weekly limit 85%',
      );
    });

    test('only a window past the warning line warns, the tightest first', () {
      expect(
        nearestLimit(const [UsageWindow(label: '5h', percent: 60)]),
        isNull,
      );
      expect(nearestLimit(const [UsageWindow(label: '5h')]), isNull);
      final limit = nearestLimit(const [
        UsageWindow(label: '5h', percent: 81),
        UsageWindow(label: 'Weekly', percent: 97),
      ]);
      expect(limit?.label, 'Weekly');
      expect(limit?.percent, 97);
    });
  });

  group('on the board', () {
    late Directory dir;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('ks-overview-usage');
    });
    tearDown(() async {
      try {
        await dir.delete(recursive: true);
      } on FileSystemException {
        // Windows may still hold the prefs file; the OS sweeps temp.
      }
    });

    testWidgets('the card and the peek say what was reported, "not recorded" '
        'otherwise, and warn near a limit', (tester) async {
      final container = await pumpMission(
        tester,
        fixture: MissionFixture.full(),
        prefsDir: dir,
        overrides: [
          overviewTokenCountsProvider.overrideWith(
            (ref) async => {'ks-r32': 1234567, 'ks-release': null},
          ),
          sessionUsageProvider.overrideWith(
            (ref, id) => id == 'ks-r32'
                ? const SessionUsageChanged(
                    sessionId: 'ks-r32',
                    contextUsed: 1000,
                    contextSize: 200000,
                    costAmount: 0.42,
                    costCurrency: 'USD',
                  )
                : null,
          ),
          overviewLimitProvider.overrideWith(
            (ref, id) => id == 'ks-release'
                ? OverviewLimit(
                    label: '5h',
                    percent: 92,
                    resetsAt: now.add(const Duration(minutes: 12)),
                  )
                : null,
          ),
        ],
      );

      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('overview-usage:ks-r32')))
            .data,
        r'1.2M tokens · $0.42',
      );
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('overview-usage:ks-release')),
            )
            .data,
        'Usage not recorded',
      );
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('overview-limit:ks-release')),
            )
            .data,
        '5h limit 92% · resets in 12m',
      );
      expect(find.byKey(const ValueKey('overview-limit:ks-r32')), findsNothing);

      container.read(overviewFocusProvider.notifier).peek('ks-r32');
      await settleMission(tester);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('overview-peek')),
          matching: find.text(r'1.2M tokens · $0.42'),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await unmountMission(tester);
    });
  });
}
