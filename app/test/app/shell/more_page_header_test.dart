import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../responsive_surfaces.dart';

/// **Every page opened from More wears one header row** (round 86): back,
/// the name at a normal size and the page's own controls — the Dashboard's
/// one row with a way back, not an app bar over a strip. On a 360 px phone
/// at 1x and 1.6x text.
void main() {
  Finder key(String k) => find.byKey(ValueKey(k));

  for (final surface in moreSurfaces) {
    for (final scale in const [1.0, 1.6]) {
      testWidgets('${surface.name} at 360 px, ${scale}x text', (tester) async {
        final build = await surface.prepare(tester, Brightness.light);
        await pumpWindow(
          tester,
          build: build,
          size: const Size(360, 780),
          textScale: scale,
        );

        expect(key('page-header'), findsOneWidget);
        expect(find.byType(AppBar, skipOffstage: true), findsNothing);
        final back = tester.getCenter(key('page-header-back'));
        final title = tester.getCenter(key('page-header-title'));
        expect((back.dy - title.dy).abs(), lessThan(1), reason: 'one row');
        // A normal-size name, not a large title.
        final style = tester.widget<Text>(key('page-header-title')).style;
        final theme = Theme.of(tester.element(key('page-header-title')));
        expect(style?.fontSize, theme.textTheme.titleMedium?.fontSize);
        // A switcher in the header keeps a thumb's target: it moves under
        // the name rather than shrinking beside it.
        for (final switcher
            in find
                .descendant(
                  of: key('page-header'),
                  matching: find.byWidgetPredicate((w) => w is SegmentedButton),
                )
                .evaluate()) {
          expect(
            tester
                .getRect(find.byElementPredicate((e) => e == switcher))
                .height,
            greaterThanOrEqualTo(48),
            reason: '${switcher.widget.key}',
          );
        }
        // Back leaves More's page.
        await tester.tap(key('page-header-back'));
        await ignoringOverflow(() => settleSurface(tester));
        expect(find.text('More'), findsWidgets);
        await tester.pump(const Duration(seconds: 30));
      });
    }
  }

  testWidgets('the Usage range sits in the header row on a phone, and at '
      '1.6x text beside the name or under it, never over it or shrunk', (
    tester,
  ) async {
    final surface = moreSurfaces.firstWhere((s) => s.name == 'more-usage');
    final build = await surface.prepare(tester, Brightness.light);
    await pumpWindow(tester, build: build, size: const Size(360, 780));
    final back = tester.getCenter(key('page-header-back'));
    expect(
      (tester.getCenter(key('usage-range')).dy - back.dy).abs(),
      lessThan(1),
    );
    // At its own size: a thumb's target, not shrunk to fit.
    expect(tester.getRect(key('usage-range')).height, greaterThanOrEqualTo(48));

    await pumpWindow(
      tester,
      build: build,
      size: const Size(360, 780),
      textScale: 1.6,
    );
    // Which, depends on the font's widths: the bundled one fits beside the
    // name (see the round 86 renders), the test font does not.
    final large = tester.getRect(key('usage-range'));
    final title = tester.getRect(key('page-header-title'));
    expect(large.overlaps(title), isFalse);
    expect(large.height, greaterThanOrEqualTo(48));
    expect(
      large.right,
      lessThanOrEqualTo(tester.getRect(key('page-header')).right),
    );
    await tester.pump(const Duration(seconds: 30));
  });
}

Future<void> pumpWindow(
  WidgetTester tester, {
  required Widget Function() build,
  required Size size,
  double textScale = 1,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await ignoringOverflow(() async {
    await tester.pumpWidget(build());
    await settleSurface(tester);
    await settleSurface(tester);
  });
}

/// The header is the question here; a page body's fit is the window
/// matrix's (`responsive_window_matrix_test.dart`), which knows its
/// exceptions.
Future<void> ignoringOverflow(Future<void> Function() body) async {
  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    if (!details.exceptionAsString().contains('overflowed')) {
      previous?.call(details);
    }
  };
  try {
    await body();
  } finally {
    FlutterError.onError = previous;
  }
}
