import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/theme/app_icons.dart';
import 'package:karmashala/src/app/theme/app_theme.dart';
import 'package:karmashala/src/app/theme/design_tokens.dart';

/// The theme answers for whole widget classes, so a call site never has to.
///
/// Each of these was a control that quietly drew a Material default beside
/// chrome built from [Chrome] and the app's own type ramp. The assertions read
/// the *rendered* glyph rather than the `ThemeData` field, because the bug was
/// never that the field was wrong — it was that the widget never asked.
void main() {
  /// The font size an [Icon] actually painted at: an icon is a glyph, so its
  /// size is the `fontSize` of the text run it renders.
  double renderedIconSize(WidgetTester tester, Finder icon) {
    final text = tester.widget<RichText>(
      find.descendant(of: icon, matching: find.byType(RichText)),
    );
    return text.text.style!.fontSize!;
  }

  Future<void> pump(WidgetTester tester, Widget child) => tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(body: Center(child: child)),
    ),
  );

  group('icon glyphs come from the theme, not Material', () {
    testWidgets('an IconButton with no size draws Chrome.icon', (tester) async {
      // An `IconButton` sizes its glyph from its own button style, not from
      // the ambient `iconTheme`, so before `iconButtonTheme` named a size this
      // was Material's 24 — inside a 30px button with 4px padding.
      await pump(
        tester,
        IconButton(
          onPressed: () {},
          icon: const Icon(AppIcons.arrowsClockwise),
        ),
      );
      expect(renderedIconSize(tester, find.byType(Icon)), Chrome.icon);
      expect(renderedIconSize(tester, find.byType(Icon)), isNot(24.0));
    });

    testWidgets('a button.icon glyph draws Chrome.icon', (tester) async {
      // Material's default for a button's leading icon is 18.
      await pump(
        tester,
        FilledButton.icon(
          onPressed: () {},
          icon: const Icon(AppIcons.paperPlaneRight),
          label: const Text('Send'),
        ),
      );
      expect(renderedIconSize(tester, find.byType(Icon)), Chrome.icon);
    });

    testWidgets('a touch surface steps up to Touch.icon', (tester) async {
      // The companion is the same design language at a thumb's scale; what
      // changes is the size, and it changes in one place.
      final touch = UiDensity.touch.themeFor(AppTheme.light());
      await tester.pumpWidget(
        MaterialApp(
          theme: touch,
          home: Scaffold(
            body: Center(
              child: FilledButton.icon(
                onPressed: () {},
                icon: const Icon(AppIcons.paperPlaneRight),
                label: const Text('Send'),
              ),
            ),
          ),
        ),
      );
      expect(renderedIconSize(tester, find.byType(Icon)), Touch.icon);
    });
  });
}
