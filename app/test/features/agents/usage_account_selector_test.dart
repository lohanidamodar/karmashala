import 'dart:io';

import 'package:agent_cli/usage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/capabilities/capabilities.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/application/usage_session_tokens.dart';
import 'package:karmashala/src/features/agents/application/usage_tab_prefs.dart';
import 'package:karmashala/src/features/agents/presentation/usage_tab/usage_tab_state.dart';
import 'package:karmashala/src/features/agents/presentation/usage_tab/usage_tab_view.dart';
import 'package:karmashala/src/features/sessions/application/capacity_providers.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_ui/charts.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';
import 'usage_fixtures.dart';

/// **The Usage tab's account selector** (round 86): one picker row, not a
/// wall of chips; accounts grouped by agent with one entry per account
/// however many machines it is read on; "not measured" for an agent with no
/// percentage; the choice filters the tiles and charts, and is remembered.
void main() {
  late TestMachine db;

  setUp(() {
    db = seedUsageDatabase();
    seedManyUsageAccounts(db.server);
    // The owner's Claude account reached its limit once in the last day.
    for (final (minutes, percent) in const [(90, 80.0), (60, 100.0)]) {
      db.server.usageRows.insert(
        UsageSample(
          accountKey: 'claudeCode@windows',
          windowLabel: '5-hour',
          span: kUsageFiveHourWindow,
          percent: percent,
          recordedAt: testTime.subtract(Duration(minutes: minutes)),
        ),
      );
    }
  });

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    Size size = const Size(1440, 900),
    UsageTabSelection? selection,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(
      overrides: [
        await db.server.override(),
        clockProvider.overrideWithValue(MovableClock(testTime)),
        serverOfferProvider.overrideWithValue(
          const ServerOffer(
            sameMachine: true,
            features: {'sessions.capacity', 'sessions.stats'},
          ),
        ),
        capacityNowProvider.overrideWithValue(CapacitySnapshot.empty),
        usageSessionRowsProvider.overrideWith((ref) async => const []),
        // Nothing kept: the page opens on every account.
        usageTabPrefsStoreProvider.overrideWithValue(
          MemoryUsageTabPrefs(selection?.toJson()),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: UsageTabView())),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  String tile(WidgetTester tester, String label) {
    final found = tester.widget<StatTile>(
      find.byWidgetPredicate((w) => w is StatTile && w.label == label),
    );
    return found.value ?? found.unrecorded;
  }

  testWidgets('one picker row on every account, never a wall of chips', (
    tester,
  ) async {
    await pump(tester);

    expect(find.byKey(const ValueKey('usage-account-picker')), findsOneWidget);
    expect(find.byType(ChoiceChip), findsNothing);
    expect(find.text('All accounts'), findsOneWidget);
    expect(find.text('6 accounts · 3 agents'), findsOneWidget);
    // Every account's tightest window, whose it is.
    expect(tile(tester, 'Tightest window'), '97%');
    expect(find.textContaining('Claude 5-hour'), findsOneWidget);
    expect(tile(tester, 'Limits hit'), '1');
    expect(
      find.byKey(const ValueKey('usage-accounts-overview')),
      findsOneWidget,
    );
  });

  testWidgets('the list groups by agent, merges an account read on two '
      'machines, and says "not measured" for Antigravity', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('usage-account-picker')));
    await tester.pumpAndSettle();

    for (final agent in ['Claude Code', 'Codex CLI', 'Antigravity']) {
      expect(find.text(agent.toUpperCase()), findsWidgets, reason: agent);
    }
    // The owner's Claude account, on Windows and the SSH machine: one row.
    final owner = find.byKey(
      ValueKey('usage-account-${'claudeCode\u0000owner@example.com'}'),
    );
    expect(owner, findsWidgets);
    expect(
      find.descendant(of: owner.last, matching: find.text('97%')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: owner.last,
        matching: find.textContaining('DLO server'),
      ),
      findsOneWidget,
    );
    // A sign-in with no email is named by where it is.
    expect(find.text('signed in on SSH · DLO server'), findsWidgets);
    // Antigravity reads no percentage: words, not an empty bar.
    expect(
      find.byKey(
        const ValueKey(
          'usage-account-unmeasured-antigravity\u0000antigravity@ssh:dlo',
        ),
      ),
      findsWidgets,
    );
    expect(find.text('not measured'), findsWidgets);
  });

  testWidgets('choosing an account filters the tiles and the charts', (
    tester,
  ) async {
    final c = await pump(tester);
    await tester.tap(find.byKey(const ValueKey('usage-account-picker')));
    await tester.pumpAndSettle();
    await tester.tap(
      find
          .byKey(const ValueKey('usage-account-codex\u0000owner@example.com'))
          .last,
    );
    await tester.pumpAndSettle();

    expect(
      c.read(usageTabSelectionProvider).accountId,
      'codex\u0000owner@example.com',
    );
    expect(find.text('Codex · owner@example.com'), findsOneWidget);
    expect(tile(tester, 'Tightest window'), '30%');
    expect(tile(tester, 'Limits hit'), 'not recorded');
    // One account's windows over time, not every account's list.
    expect(find.text('WINDOWS OVER TIME'), findsOneWidget);
    expect(find.byKey(const ValueKey('usage-accounts-overview')), findsNothing);

    // And back to every account.
    await tester.tap(find.byKey(const ValueKey('usage-account-picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('usage-account-all')).last);
    await tester.pumpAndSettle();
    expect(c.read(usageTabSelectionProvider).accountId, isNull);
    expect(tile(tester, 'Tightest window'), '97%');
  });

  testWidgets('a kept choice of an account since gone shows every account', (
    tester,
  ) async {
    await pump(
      tester,
      selection: const UsageTabSelection(accountId: 'gone\u0000x@example.com'),
    );
    expect(find.text('All accounts'), findsOneWidget);
  });

  testWidgets('on a phone the list is a bottom sheet', (tester) async {
    await pump(tester, size: const Size(360, 780));
    await tester.tap(find.byKey(const ValueKey('usage-account-picker')));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('the choice is remembered on this device', () async {
    final dir = await Directory.systemTemp.createTemp('usage-tab-prefs');
    addTearDown(() => dir.delete(recursive: true));
    ProviderContainer make() => ProviderContainer(
      overrides: [
        usageTabPrefsDirectoryProvider.overrideWithValue(() async => dir),
      ],
    );

    final first = make();
    first.read(usageTabSelectionProvider);
    final controller = first.read(usageTabSelectionProvider.notifier)
      ..selectAccount('codex\u0000owner@example.com')
      ..selectRange(UsageRange.month);
    await controller.written;
    first.dispose();

    final second = make();
    addTearDown(second.dispose);
    second.read(usageTabSelectionProvider);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final kept = second.read(usageTabSelectionProvider);
    expect(kept.accountId, 'codex\u0000owner@example.com');
    expect(kept.range, UsageRange.month);
  });
}
