import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/menus.dart';

/// The house menu row, and the two-line sibling that had to exist before the
/// pickers could stop drawing menu chrome of their own.
///
/// A plain `PopupMenuItem` is 48px tall with no leading glyph, which is exactly
/// what every converted menu used to be: a different rhythm from the Explorer's
/// menus sitting inches away.
void main() {
  /// The size a run of text was actually painted at, whoever decided it.
  double renderedTextSize(WidgetTester tester, Finder text) {
    final rich = tester.widget<RichText>(
      find.descendant(of: text, matching: find.byType(RichText)),
    );
    return rich.text.style!.fontSize!;
  }

  Color renderedTextColor(WidgetTester tester, Finder text) {
    final rich = tester.widget<RichText>(
      find.descendant(of: text, matching: find.byType(RichText)),
    );
    return rich.text.style!.color!;
  }

  /// Opens a menu of [items] and returns nothing until it is on screen.
  Future<void> open(
    WidgetTester tester,
    List<PopupMenuEntry<String>> items, {
    ValueChanged<String>? onSelected,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Center(
            child: PopupMenuButton<String>(
              itemBuilder: (_) => items,
              onSelected: onSelected,
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  group('the one-line row', () {
    testWidgets('is Chrome.menuRow tall, icon-led and on the type ramp', (
      tester,
    ) async {
      await open(tester, [
        DesktopMenuItem(value: 'copy', label: 'Copy path', icon: AppIcons.copy),
      ]);

      expect(
        tester.getSize(find.byType(DesktopMenuItem<String>)).height,
        Chrome.menuRow,
      );
      expect(find.byIcon(AppIcons.copy), findsOneWidget);
      final theme = Theme.of(tester.element(find.text('Copy path')));
      expect(
        renderedTextSize(tester, find.text('Copy path')),
        theme.textTheme.bodySmall!.fontSize,
      );
    });

    testWidgets('a destructive row is drawn in the error colour', (
      tester,
    ) async {
      await open(tester, [
        DesktopMenuItem(
          value: 'delete',
          label: 'Delete',
          icon: AppIcons.trash,
          destructive: true,
        ),
      ]);
      final scheme = Theme.of(tester.element(find.text('Delete'))).colorScheme;
      expect(renderedTextColor(tester, find.text('Delete')), scheme.error);
    });

    testWidgets('a selected row wears the check instead of its icon', (
      tester,
    ) async {
      await open(tester, [
        DesktopMenuItem(
          value: 'wsl',
          label: 'WSL',
          icon: AppIcons.terminal,
          selected: true,
        ),
      ]);
      expect(find.byIcon(AppIcons.check), findsOneWidget);
      expect(find.byIcon(AppIcons.terminal), findsNothing);
      final scheme = Theme.of(tester.element(find.text('WSL'))).colorScheme;
      expect(renderedTextColor(tester, find.text('WSL')), scheme.primary);
    });

    testWidgets('a shortcut is written on the right of the row', (
      tester,
    ) async {
      await open(tester, [
        DesktopMenuItem(
          value: 'rename',
          label: 'Rename',
          icon: AppIcons.pencilSimple,
          shortcut: 'F2',
        ),
      ]);
      expect(find.text('F2'), findsOneWidget);
    });

    testWidgets('a pick reaches the host', (tester) async {
      String? picked;
      await open(tester, [
        DesktopMenuItem(value: 'copy', label: 'Copy path', icon: AppIcons.copy),
      ], onSelected: (value) => picked = value);
      await tester.tap(find.text('Copy path'));
      await tester.pumpAndSettle();
      expect(picked, 'copy');
    });
  });

  group('the two-line row', () {
    testWidgets('says both lines, on the taller rhythm', (tester) async {
      await open(tester, [
        DesktopMenuDetailItem(
          value: 'ask',
          label: 'Ask',
          detail: 'Claude Code supports this mode.',
          badge: 'exact',
        ),
      ]);

      expect(
        tester.getSize(find.byType(DesktopMenuDetailItem<String>)).height,
        greaterThanOrEqualTo(Chrome.menuRowTall),
      );
      expect(find.text('Ask'), findsOneWidget);
      expect(find.text('exact'), findsOneWidget);
      expect(find.text('Claude Code supports this mode.'), findsOneWidget);

      final theme = Theme.of(tester.element(find.text('Ask')));
      expect(
        renderedTextSize(tester, find.text('Ask')),
        theme.textTheme.bodySmall!.fontSize,
      );
      expect(
        renderedTextSize(tester, find.text('exact')),
        theme.textTheme.labelSmall!.fontSize,
      );
    });

    testWidgets('the selected row is the checked one', (tester) async {
      await open(tester, [
        DesktopMenuDetailItem(
          value: 'app',
          label: 'app',
          detail: 'main  ·  projects/app',
          icon: AppIcons.bookBookmark,
          selected: true,
        ),
        DesktopMenuDetailItem(
          value: 'hub',
          label: 'demo',
          detail: 'main  ·  project root',
          icon: AppIcons.bookBookmark,
        ),
      ]);
      expect(find.byIcon(AppIcons.check), findsOneWidget);
      expect(find.byIcon(AppIcons.bookBookmark), findsOneWidget);
    });

    testWidgets('a disabled row is muted and cannot be picked', (tester) async {
      String? picked;
      await open(tester, [
        DesktopMenuDetailItem(
          value: 'bypass',
          label: 'Bypass',
          detail: 'This agent takes no flag for this.',
          enabled: false,
        ),
      ], onSelected: (value) => picked = value);
      final scheme = Theme.of(tester.element(find.text('Bypass'))).colorScheme;
      expect(
        renderedTextColor(tester, find.text('Bypass')),
        scheme.onSurfaceVariant,
      );
      await tester.tap(find.text('Bypass'));
      await tester.pumpAndSettle();
      expect(picked, isNull);
    });

    testWidgets('.live draws a row that arrives after the menu does', (
      tester,
    ) async {
      // The checkout picker's shape: `git worktree list` answers while the menu
      // is already on screen.
      final branch = ValueNotifier<String?>(null);
      addTearDown(branch.dispose);
      await open(tester, [
        DesktopMenuDetailItem<String>.live(
          value: 'relay',
          child: ValueListenableBuilder<String?>(
            valueListenable: branch,
            builder: (_, value, _) => DesktopMenuDetailRow(
              label: 'wt-relay',
              detail: value ?? 'projects/wt-relay',
              icon: AppIcons.bookBookmark,
            ),
          ),
        ),
      ]);
      expect(find.text('projects/wt-relay'), findsOneWidget);

      branch.value = 'worktree  ·  dual-relay  ·  projects/wt-relay';
      await tester.pumpAndSettle();
      expect(
        find.text('worktree  ·  dual-relay  ·  projects/wt-relay'),
        findsOneWidget,
      );
    });
  });
}
