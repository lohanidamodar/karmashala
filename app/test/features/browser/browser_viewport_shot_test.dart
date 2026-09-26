import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/browser/application/browser_providers.dart';
import 'package:karmashala/src/features/browser/presentation/browser_pane.dart';
import 'package:karmashala/src/features/browser/presentation/browser_viewport_shot.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import 'fake_browser.dart';

/// **A picture of the viewport, from the pane.**
///
/// The finding this closes: the pane could only ever show the crop a pick
/// produced — one element, out of its surroundings — and never the thing a
/// person is usually asking about, which is what the page looks like now.
void main() {
  late FakeBrowser fake;

  setUp(() {
    fake = FakeBrowser();
    fake.onEvaluate = (expression) {
      if (expression.contains('__karmashalaPicker')) return true;
      if (expression == 'location.href') return 'https://example.com/app';
      if (expression == 'document.title') return 'Example';
      return null;
    };
  });

  Future<ProviderContainer> pump(WidgetTester tester) async {
    final container = ProviderContainer(
      overrides: [
        browserServiceProvider.overrideWithValue(fake.service),
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

  testWidgets('nothing to screenshot until a browser is attached', (
    tester,
  ) async {
    await pump(tester);

    expect(find.byType(BrowserViewportShotButton), findsOneWidget);
    // `find.byTooltip` lands on the tooltip, not the control wearing it.
    expect(
      tester
          .widget<IconButton>(
            find.ancestor(
              of: find.byTooltip('Screenshot the viewport'),
              matching: find.byType(IconButton),
            ),
          )
          .onPressed,
      isNull,
    );
  });

  testWidgets('it captures the viewport and says how old the picture is', (
    tester,
  ) async {
    final container = await pump(tester);
    await tester.tap(find.text('Attach · 9222'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Screenshot the viewport'));
    await tester.pumpAndSettle();

    // No selector and no fullPage: the viewport is what the developer is
    // looking at, and the crop beside it already covers one element.
    final shot = fake.framesFor('Page.captureScreenshot');
    expect(shot, hasLength(1));
    expect(shot.single['clip'], isNull);
    expect(container.read(browserViewportShotProvider).png, isNotNull);
    expect(find.byType(Image), findsWidgets);
    // §19: a picture of a page is true of the moment it was taken.
    expect(find.textContaining('The viewport, just now'), findsOneWidget);
  });

  testWidgets('clearing it puts the pane back to its own words', (
    tester,
  ) async {
    final container = await pump(tester);
    await tester.tap(find.text('Attach · 9222'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Screenshot the viewport'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(TextButton, 'Clear'));
    await tester.pumpAndSettle();

    expect(container.read(browserViewportShotProvider).isEmpty, isTrue);
    expect(find.textContaining('Pick an element'), findsOneWidget);
  });

  test('an unasked-for shot is empty, not a blank picture', () {
    // The distinction the pane switches on: nothing has been asked for, so the
    // pane says its own words rather than drawing an absence.
    expect(const BrowserViewportShot().isEmpty, isTrue);
    expect(const BrowserViewportShot(problem: 'refused').isEmpty, isFalse);
  });
}
