import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/status_bar_items.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/tokens.dart';

/// The status bar's building blocks, on their own.
void main() {
  Widget host(List<Widget> children) => MaterialApp(
    theme: AppTheme.light(),
    home: Scaffold(
      body: Align(
        alignment: Alignment.bottomLeft,
        child: SizedBox(
          height: Chrome.statusBar,
          child: Row(children: children),
        ),
      ),
    ),
  );

  testWidgets('an item with an action is a named, focusable button', (
    tester,
  ) async {
    var pressed = 0;
    await tester.pumpWidget(
      host([
        StatusBarItem(
          icon: AppIcons.gitBranch,
          label: 'main',
          tooltip: 'Branch main. Click to open Changes.',
          onPressed: () => pressed++,
        ),
      ]),
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    final ring = tester.widget<DecoratedBox>(
      find.descendant(
        of: find.byType(StatusBarItem),
        matching: find.byWidgetPredicate(
          (w) =>
              w is DecoratedBox && w.position == DecorationPosition.foreground,
        ),
      ),
    );
    expect(
      (ring.decoration as BoxDecoration).border,
      isNotNull,
      reason: 'keyboard focus draws the inset ring',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(pressed, 1);
    expect(
      find.byTooltip('Branch main. Click to open Changes.'),
      findsOneWidget,
    );
  });

  testWidgets('a hover wash comes from StateLayers, not the accent', (
    tester,
  ) async {
    await tester.pumpWidget(
      host([
        StatusBarItem(
          icon: AppIcons.tray,
          label: '2 need you',
          tooltip: 'Inbox',
          onPressed: () {},
        ),
      ]),
    );
    final scheme = Theme.of(
      tester.element(find.byType(StatusBarItem)),
    ).colorScheme;
    final ink = tester.widget<InkWell>(find.byType(InkWell));
    expect(ink.hoverColor, StateLayers.hover(scheme));
    expect(ink.highlightColor, StateLayers.pressed(scheme));
    expect(ink.hoverDuration, Motion.instant);
  });

  testWidgets('an item with nowhere to go is not a focus stop', (tester) async {
    await tester.pumpWidget(
      host([
        const StatusBarItem(
          icon: AppIcons.terminal,
          label: '3 tabs',
          tooltip: '3 open tabs in this window.',
        ),
      ]),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(find.byType(InkWell), findsNothing);
    expect(
      FocusManager.instance.primaryFocus?.context?.widget,
      isNot(isA<InkWell>()),
    );
  });

  testWidgets('a glyph-only item is named by its tooltip', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      host([
        StatusBarItem(
          icon: AppIcons.sidebarSimple,
          tooltip: 'Side panel closed. Click to open it.',
          onPressed: () {},
        ),
      ]),
    );
    expect(find.bySemanticsLabel(RegExp('Side panel closed')), findsWidgets);
    semantics.dispose();
  });

  testWidgets('tone colours the glyph and the words with meaning', (
    tester,
  ) async {
    await tester.pumpWidget(
      host([
        const StatusBarItem(
          icon: AppIcons.tray,
          label: '4 need you',
          tooltip: 'Inbox',
          tone: StatusBarTone.attention,
        ),
      ]),
    );
    final context = tester.element(find.byType(StatusBarItem));
    final attention = SemanticColors.of(context).attention;
    expect(tester.widget<Icon>(find.byIcon(AppIcons.tray)).color, attention);
    expect(
      tester.widget<Text>(find.text('4 need you')).style?.color,
      attention,
    );
  });

  testWidgets('a flexible label ends instead of overflowing', (tester) async {
    await tester.pumpWidget(
      host([
        const SizedBox(
          width: 90,
          child: Row(
            children: [
              Flexible(
                child: StatusBarItem(
                  icon: AppIcons.bookBookmark,
                  label: 'a-repository-name-far-too-long-for-its-room',
                  tooltip: 'Repository',
                  flexible: true,
                ),
              ),
            ],
          ),
        ),
      ]),
    );
    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.byType(StatusBarItem)).width,
      lessThanOrEqualTo(90),
    );
  });

  testWidgets('the overflow menu lists entries and runs their actions', (
    tester,
  ) async {
    var opened = 0;
    await tester.pumpWidget(
      host([
        StatusBarOverflow(
          entries: () => [
            StatusBarOverflowEntry(
              icon: AppIcons.bookBookmark,
              label: 'karmashala-app',
              onPressed: () => opened++,
            ),
            const StatusBarOverflowEntry(
              icon: AppIcons.terminal,
              label: '3 tabs',
            ),
          ],
        ),
      ]),
    );

    await tester.tap(find.byIcon(AppIcons.dotsThree));
    await tester.pumpAndSettle();
    final tabs = tester.widget<PopupMenuItem<int>>(
      find.ancestor(
        of: find.text('3 tabs'),
        matching: find.byWidgetPredicate((w) => w is PopupMenuItem<int>),
      ),
    );
    expect(tabs.enabled, isFalse, reason: 'a fact with no action is listed');

    await tester.tap(find.text('karmashala-app'));
    await tester.pumpAndSettle();
    expect(opened, 1);
  });
}
