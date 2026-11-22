import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/presentation/toolbar_usage_strip.dart';
import 'package:karmashala/src/features/agents/presentation/usage_chip_popover.dart';
import 'package:karmashala/src/features/notifications/application/notification_providers.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import 'usage_fixtures.dart';

/// The phone's top bar carries the desktop toolbar's usage: the tightest
/// account at a glance, and every account's card one tap away.
void main() {
  Future<ProviderContainer> pump(
    WidgetTester tester, {
    bool signedIn = true,
    double width = 400,
    double textScale = 1,
  }) async {
    tester.view.physicalSize = Size(width, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final db = seedUsageDatabase();
    if (signedIn) {
      for (final (agent, percent) in [
        ('claudeCode', 30.0),
        ('codex', 90.0),
        ('geminiCli', 50.0),
      ]) {
        seedUsage(
          db.server,
          agentInstallation(agentId: agent, environmentId: 'windows'),
          usage: usageSnapshot(percent: percent, email: 'me@x.io'),
        );
      }
    }
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
          home: MediaQuery.withClampedTextScaling(
            minScaleFactor: textScale,
            maxScaleFactor: textScale,
            child: Scaffold(
              // A phone's top bar as crowded as it gets: the server's name,
              // the route chip, the bot, search and the needs-you count.
              appBar: AppBar(
                title: const Text('This computer'),
                actions: const [
                  SizedBox(width: 96),
                  PhoneUsageButton(),
                  SizedBox(width: 48 * 3),
                ],
              ),
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

  final button = find.byKey(const ValueKey('phone-top-usage'));

  testWidgets('nothing is drawn while no account is signed in', (tester) async {
    final container = await pump(tester, signedIn: false);
    expect(button, findsNothing);
    await quiesce(tester, container);
  });

  testWidgets('it shows the tightest account, and how many more there are', (
    tester,
  ) async {
    final container = await pump(tester);
    expect(button, findsOneWidget);
    expect(
      find.descendant(of: button, matching: find.text('90%')),
      findsOneWidget,
      reason: 'Codex, at 90%, is the nearest its limit',
    );
    expect(
      find.descendant(of: button, matching: find.text('+2')),
      findsOneWidget,
    );
    await quiesce(tester, container);
  });

  testWidgets('a tap opens every account\'s card in one sheet', (tester) async {
    final container = await pump(tester);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.text('Usage'), findsOneWidget);
    expect(find.byType(UsageChipPopover), findsNWidgets(3));
    expect(find.text('Refresh'), findsNWidgets(3));
    expect(find.text('Details'), findsNWidgets(3));
    await quiesce(tester, container);
  });

  for (final width in [360.0, 600.0]) {
    testWidgets('fits at ${width.toInt()} px and text scale 1.6', (
      tester,
    ) async {
      final container = await pump(tester, width: width, textScale: 1.6);
      expect(tester.takeException(), isNull);
      expect(button, findsOneWidget);
      expect(tester.getSize(button).width, lessThanOrEqualTo(88));
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(UsageChipPopover), findsWidgets);
      await quiesce(tester, container);
    });
  }
}
