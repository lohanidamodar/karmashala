import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/menus.dart';

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

  /// The size a run of text was actually painted at, whoever decided it.
  double renderedTextSize(WidgetTester tester, Finder text) {
    final rich = tester.widget<RichText>(
      find.descendant(of: text, matching: find.byType(RichText)),
    );
    return rich.text.style!.fontSize!;
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

  test('the type ramp carries its sizes into the component themes', () {
    // `typography.black`/`.white` hold colour and family and *no font sizes*;
    // the sizes live in the geometry, which `ThemeData.localize` merges into
    // `ThemeData.textTheme` and nowhere else. So every component theme entry
    // that captured one of these styles captured a null `fontSize` and
    // inherited whatever was ambient — a menu, a dialog and a chip each
    // ignoring the ramp step they name. The geometry is merged in the theme
    // now, and these assert it reaches the components rather than only the
    // ramp.
    final theme = AppTheme.light();
    final ramp = theme.textTheme;
    expect(ramp.bodySmall?.fontSize, isNotNull);
    expect(theme.popupMenuTheme.textStyle?.fontSize, ramp.bodySmall!.fontSize);
    expect(
      theme.popupMenuTheme.labelTextStyle?.resolve({})?.fontSize,
      ramp.bodySmall!.fontSize,
    );
    expect(
      theme.dialogTheme.titleTextStyle?.fontSize,
      ramp.titleMedium!.fontSize,
    );
    expect(
      theme.dialogTheme.contentTextStyle?.fontSize,
      ramp.bodyMedium!.fontSize,
    );
    expect(theme.chipTheme.labelStyle?.fontSize, ramp.labelMedium!.fontSize);
    expect(theme.tooltipTheme.textStyle?.fontSize, ramp.labelSmall!.fontSize);
    expect(
      theme.listTileTheme.titleTextStyle?.fontSize,
      ramp.bodyMedium!.fontSize,
    );
    expect(
      theme.menuButtonTheme.style?.textStyle?.resolve({})?.fontSize,
      ramp.bodySmall!.fontSize,
    );
  });

  testWidgets('a plain PopupMenuItem is the size the menu theme names', (
    tester,
  ) async {
    // Under Material 3 `PopupMenuItem` reads `labelTextStyle` and ignores
    // `textStyle`, so it drew at `labelLarge`/14 beside a `DesktopMenuItem`
    // drawing its own `bodySmall`/12 in the same menu.
    await pump(
      tester,
      Builder(
        builder: (context) => PopupMenuButton<int>(
          itemBuilder: (_) => [
            const PopupMenuItem(value: 1, child: Text('Close pane')),
            DesktopMenuItem(value: 2, label: 'Copy path', icon: AppIcons.copy),
          ],
          child: const Text('open'),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final theme = Theme.of(tester.element(find.text('Close pane')));
    expect(
      renderedTextSize(tester, find.text('Close pane')),
      theme.textTheme.bodySmall!.fontSize,
    );
    // The two kinds of item sit in the same menu; they must read as one list.
    expect(
      renderedTextSize(tester, find.text('Close pane')),
      renderedTextSize(tester, find.text('Copy path')),
    );
  });

  test('a text field is an outlined box at the chrome\'s own radius', () {
    // So a field that declares no border of its own gets this one rather than
    // Material's 4px `OutlineInputBorder()`.
    final border = AppTheme.light().inputDecorationTheme.border;
    expect(border, isA<OutlineInputBorder>());
    expect(
      (border! as OutlineInputBorder).borderRadius,
      BorderRadius.circular(Radii.sm),
    );
  });

  testWidgets('a ListTile title is the chrome\'s body, not Material\'s', (
    tester,
  ) async {
    // Material's default is `bodyLarge` — bigger than the `bodyMedium` a
    // dialog sets its own content text in, so a tile shouted over the sentence
    // explaining it. Most call sites pass a bare `Text` and inherited it.
    await pump(
      tester,
      const ListTile(title: Text('Run in a worktree'), subtitle: Text('why')),
    );
    final theme = Theme.of(tester.element(find.byType(ListTile)));
    final title = tester.widget<Text>(find.text('Run in a worktree'));
    expect(title.style, isNull, reason: 'the tile, not the call site, decides');
    expect(
      renderedTextSize(tester, find.text('Run in a worktree')),
      theme.textTheme.bodyMedium!.fontSize,
    );
    expect(
      renderedTextSize(tester, find.text('Run in a worktree')),
      isNot(theme.textTheme.bodyLarge!.fontSize),
    );
    expect(
      renderedTextSize(tester, find.text('why')),
      theme.textTheme.bodySmall!.fontSize,
    );
  });
}
