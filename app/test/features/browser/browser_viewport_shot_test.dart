import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/browser/presentation/browser_pane.dart';
import 'package:karmashala/src/features/browser/presentation/browser_viewport_shot.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// **A picture of the viewport, from the pane** — taken by the server's
/// browser (slice 3d), which on a headless box is the only way to see it.
void main() {
  late FakeDataServer server;
  final pixel = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGA'
    'hKmMIQAAAABJRU5ErkJggg==',
  );

  Future<ProviderContainer> pump(WidgetTester tester) async {
    server = FakeDataServer();
    final container = ProviderContainer(
      overrides: [
        await server.override(),
        clockProvider.overrideWithValue(FixedClock(testTime)),
      ],
    );
    addTearDown(container.dispose);
    tester.view
      ..physicalSize = const Size(900, 1100)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: BrowserPane())),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  Future<void> attach(WidgetTester tester) async {
    server.runs.setBrowser(
      const BrowserState(
        status: BrowserStatus.connected,
        connection: 'Launched Chrome on port 9222 with an isolated profile',
        headless: true,
      ),
    );
    server.runs.onBrowser = (_) => pixel;
    await tester.runAsync(pumpEventQueue);
    await tester.pumpAndSettle();
  }

  Finder shotButton() => find.ancestor(
    of: find.byTooltip('Screenshot the viewport'),
    matching: find.byType(IconButton),
  );

  testWidgets('nothing to screenshot until a browser is attached', (
    tester,
  ) async {
    await pump(tester);
    expect(find.byType(BrowserViewportShotButton), findsOneWidget);
    expect(tester.widget<IconButton>(shotButton()).onPressed, isNull);
  });

  testWidgets('it asks the server for the viewport and says how old it is', (
    tester,
  ) async {
    final container = await pump(tester);
    await attach(tester);

    await tester.tap(find.byTooltip('Screenshot the viewport'));
    await tester.runAsync(pumpEventQueue);
    await tester.pumpAndSettle();

    expect(server.runs.asked.whereType<BrowserScreenshot>(), hasLength(1));
    expect(container.read(browserViewportShotProvider).png, isNotNull);
    expect(find.byType(Image), findsWidgets);
    // §19: a picture of a page is true of the moment it was taken.
    expect(find.textContaining('The viewport, just now'), findsOneWidget);
  });

  testWidgets('clearing it puts the pane back to its own words', (
    tester,
  ) async {
    final container = await pump(tester);
    await attach(tester);
    await tester.tap(find.byTooltip('Screenshot the viewport'));
    await tester.runAsync(pumpEventQueue);
    await tester.pumpAndSettle();
    expect(container.read(browserViewportShotProvider).png, isNotNull);

    // A decoded picture fills the pane's width, so its button is scrolled to.
    await tester.scrollUntilVisible(
      find.widgetWithText(TextButton, 'Clear'),
      200,
      scrollable: find.descendant(
        of: find.byType(BrowserViewportShotView),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.tap(find.widgetWithText(TextButton, 'Clear'));
    await tester.pumpAndSettle();

    expect(container.read(browserViewportShotProvider).isEmpty, isTrue);
  });

  test('an unasked-for shot is empty, not a blank picture', () {
    expect(const BrowserViewportShot().isEmpty, isTrue);
    expect(const BrowserViewportShot(problem: 'refused').isEmpty, isFalse);
  });
}
