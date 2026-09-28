import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/presentation/toolbar_usage_strip.dart';
import 'package:karmashala/src/features/agents/presentation/usage_chip_popover.dart';
import 'package:karmashala/src/features/notifications/application/notification_providers.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import 'usage_fixtures.dart';

/// The toolbar's accounts: one chip per signed-in account, most constrained
/// first, and what does not fit folded into `+N`.
void main() {
  test('chips fit whole, and a fold leaves room for its +N', () {
    expect(toolbarUsageChipsThatFit(5 * kToolbarUsageChipWidth, 5), 5);
    expect(
      toolbarUsageChipsThatFit(2 * kToolbarUsageChipWidth + 50, 5),
      2,
      reason: 'two chips and the +3 beside them',
    );
    expect(toolbarUsageChipsThatFit(30, 5), 0, reason: 'only the +5');
  });

  Future<ProviderContainer> accounts(WidgetTester tester, double width) async {
    final db = seedUsageDatabase();
    // Five readings: Claude on two environments under one email is one
    // account, so four chips' worth.
    seedUsage(
      db.server,
      agentInstallation(agentId: 'claudeCode', environmentId: 'windows'),
      usage: usageSnapshot(percent: 30, email: 'me@x.io'),
    );
    seedUsage(
      db.server,
      agentInstallation(agentId: 'claudeCode', environmentId: 'wsl'),
      usage: usageSnapshot(percent: 30, email: 'me@x.io'),
    );
    seedUsage(
      db.server,
      agentInstallation(agentId: 'codex', environmentId: 'windows'),
      usage: usageSnapshot(percent: 90, email: 'me@x.io'),
    );
    seedUsage(
      db.server,
      agentInstallation(agentId: 'antigravity', environmentId: 'windows'),
      usage: usageSnapshot(percent: 10, email: 'me@x.io'),
    );
    seedUsage(
      db.server,
      agentInstallation(agentId: 'geminiCli', environmentId: 'windows'),
      usage: usageSnapshot(percent: 50, email: 'me@x.io'),
    );
    final container = ProviderContainer(
      overrides: [
        await db.server.override(),
        clockProvider.overrideWithValue(MovableClock(testTime)),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(width: width, child: const ToolbarUsageStrip()),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return container;
  }

  Future<void> quiesce(WidgetTester tester, ProviderContainer container) async {
    container.read(windowFocusedProvider.notifier).set(false);
    await tester.pump();
  }

  testWidgets('one account signed in from two environments is one chip, and '
      'the tightest account comes first', (tester) async {
    final container = await accounts(tester, 1000);

    final chips = find.byWidgetPredicate(
      (w) => w is InkWell && '${w.key}'.contains('toolbar-usage-'),
    );
    expect(chips, findsNWidgets(4), reason: 'Claude is one account');
    final firstKey = '${tester.widget<InkWell>(chips.first).key}';
    expect(firstKey, contains('codex'), reason: 'at 90%, it is nearest');
    expect(find.text('90% · 2h11m'), findsOneWidget);

    // Each chip wears its agent's mark, as its adapter names it.
    Finder asset(String name) => find.byWidgetPredicate(
      (w) =>
          w is Image &&
          w.image is AssetImage &&
          (w.image as AssetImage).assetName == name,
    );
    expect(asset('assets/agents/claude.png'), findsOneWidget);
    expect(asset('assets/agents/antigravity.png'), findsOneWidget);
    expect(find.byIcon(AppIcons.openAiLogo), findsOneWidget);
    await quiesce(tester, container);
  });

  testWidgets('what does not fit folds into +N, whose card lists them all', (
    tester,
  ) async {
    final container = await accounts(tester, 2 * kToolbarUsageChipWidth + 50);

    expect(find.text('+2'), findsOneWidget);
    await tester.tap(find.text('+2'));
    await tester.pumpAndSettle();
    expect(find.byType(UsageChipPopover), findsNWidgets(2));
    await quiesce(tester, container);
  });

  testWidgets('the merged account\'s card names both environments', (
    tester,
  ) async {
    final container = await accounts(tester, 1000);
    await tester.tap(find.text('30% · 2h11m'));
    await tester.pumpAndSettle();
    final card = tester.widget<UsageChipPopover>(find.byType(UsageChipPopover));
    expect(card.environmentIds, unorderedEquals(['windows', 'wsl']));
    await quiesce(tester, container);
  });
}
