import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/tokens.dart';

/// The density decision, which used to be `width < 600 ? touch : pointer`.
///
/// That rule was wrong in one direction that shipped and one that would have:
/// a 10-inch tablet is 800–1200px and is held in a hand, so it was drawn for a
/// mouse it does not have; and a desktop window dragged under 600px is still a
/// mouse, so it would have grown 48dp targets under one. **Width was standing
/// in for input modality**, and no rule keyed on width alone can get both of
/// those right — which is why the assertions below sweep a range of widths and
/// expect the answer never to move.
///
/// What moves it is the platform. The two halves of that trade are asserted
/// too: a touch on a Windows laptop's screen does not shrink it to a phone,
/// and a mouse on an Android tablet does not shrink it to a desktop.
void main() {
  /// The density that reached a widget under [UiDensity.wrap] — the real path,
  /// `MaterialApp.builder` and all, not a hand-built scope.
  late UiDensity seen;

  Widget host(TargetPlatform platform) => MaterialApp(
    theme: AppTheme.light().copyWith(platform: platform),
    builder: (context, child) => UiDensity.wrap(context, child!),
    home: Scaffold(
      body: Builder(
        builder: (context) {
          seen = UiDensity.of(context);
          return Center(
            child: IconButton(
              onPressed: () {},
              icon: const Icon(AppIcons.arrowsClockwise),
            ),
          );
        },
      ),
    ),
  );

  Future<void> pumpAt(
    WidgetTester tester, {
    required TargetPlatform platform,
    required Size size,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(host(platform));
    await tester.pumpAndSettle();
  }

  /// The button as it was actually laid out. The whole point of [UiDensity] is
  /// the hit area, so the proof is the rendered box and not a `ThemeData`
  /// field: the desktop caps an `IconButton` at 30px, and a thumb needs 48.
  Size targetSize(WidgetTester tester) =>
      tester.getSize(find.byType(IconButton));

  group('the platform decides', () {
    test('every platform is one or the other, and says which', () {
      expect(UiDensity.forPlatform(TargetPlatform.android), UiDensity.touch);
      expect(UiDensity.forPlatform(TargetPlatform.iOS), UiDensity.touch);
      expect(UiDensity.forPlatform(TargetPlatform.fuchsia), UiDensity.touch);
      expect(UiDensity.forPlatform(TargetPlatform.windows), UiDensity.pointer);
      expect(UiDensity.forPlatform(TargetPlatform.macOS), UiDensity.pointer);
      expect(UiDensity.forPlatform(TargetPlatform.linux), UiDensity.pointer);
    });

    testWidgets('with no scope over it, a widget is the desktop', (
      tester,
    ) async {
      // Unchanged, and load-bearing: the desktop build never calls `wrap`, so
      // this default is what every Explorer row on Windows draws at.
      late UiDensity unscoped;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Builder(
            builder: (context) {
              unscoped = UiDensity.of(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(unscoped, UiDensity.pointer);
    });
  });

  group('a width never moves the answer', () {
    // Both sides of the old breakpoint, plus the two sizes CLAUDE.md §11 names
    // and the tablet the bug was reported for.
    const widths = [320.0, 390.0, 500.0, 599.0, 600.0, 834.0, 1000.0, 1440.0];

    for (final width in widths) {
      testWidgets('a phone or tablet at ${width.toInt()}px is a thumb', (
        tester,
      ) async {
        await pumpAt(
          tester,
          platform: TargetPlatform.android,
          size: Size(width, 900),
        );
        expect(seen, UiDensity.touch);
        expect(targetSize(tester).height, Touch.target);
      });

      testWidgets('a desktop window at ${width.toInt()}px is a mouse', (
        tester,
      ) async {
        await pumpAt(
          tester,
          platform: TargetPlatform.windows,
          size: Size(width, 900),
        );
        expect(seen, UiDensity.pointer);
        expect(targetSize(tester).height, lessThan(Touch.target));
      });
    }

    testWidgets('and neither does resizing across the breakpoint', (
      tester,
    ) async {
      // The regression the old rule would produce live, not just at launch:
      // dragging a desktop window narrow used to cross 600 and re-theme the
      // whole app under the cursor.
      await pumpAt(
        tester,
        platform: TargetPlatform.windows,
        size: const Size(1200, 900),
      );
      expect(seen, UiDensity.pointer);

      tester.view.physicalSize = const Size(500, 900);
      await tester.pumpAndSettle();
      expect(seen, UiDensity.pointer);
      expect(targetSize(tester).height, lessThan(Touch.target));
    });

    testWidgets('nor rotating a tablet into 1000px of landscape', (
      tester,
    ) async {
      await pumpAt(
        tester,
        platform: TargetPlatform.android,
        size: const Size(800, 1280),
      );
      expect(seen, UiDensity.touch);

      tester.view.physicalSize = const Size(1280, 800);
      await tester.pumpAndSettle();
      expect(seen, UiDensity.touch);
      expect(targetSize(tester).height, Touch.target);
    });
  });

  group('the input hardware is not consulted, deliberately', () {
    testWidgets('a touch on a desktop screen is still a mouse surface', (
      tester,
    ) async {
      // Most Windows laptops have a touchscreen and almost nobody drives one
      // with it. Promoting the app to 48dp targets the first time somebody
      // poked the panel would be the same error as the width rule, pointed the
      // other way.
      await pumpAt(
        tester,
        platform: TargetPlatform.windows,
        size: const Size(1440, 900),
      );
      await tester.tap(find.byType(IconButton), kind: PointerDeviceKind.touch);
      await tester.pumpAndSettle();

      expect(seen, UiDensity.pointer);
      expect(targetSize(tester).height, lessThan(Touch.target));
    });

    testWidgets('a mouse on a tablet is still a touch surface', (tester) async {
      // The other half: a Bluetooth mouse, or an iPad's trackpad, arrives as a
      // hovering `PointerDeviceKind.mouse` — and the device is still held in a
      // hand. Apple keeps its 44pt targets there for the same reason.
      await pumpAt(
        tester,
        platform: TargetPlatform.android,
        size: const Size(1000, 800),
      );
      final button = tester.getCenter(find.byType(IconButton));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: button);
      addTearDown(mouse.removePointer);
      await tester.pumpAndSettle();

      expect(seen, UiDensity.touch);
      expect(targetSize(tester).height, Touch.target);
    });
  });
}
