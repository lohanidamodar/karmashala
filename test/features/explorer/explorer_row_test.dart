import 'package:karmashala/src/app/theme/app_icons.dart';
import 'package:karmashala/src/app/theme/app_theme.dart';
import 'package:karmashala/src/app/theme/design_tokens.dart';
import 'package:karmashala/src/app/widgets/desktop_menu.dart';
import 'package:karmashala/src/features/explorer/application/session_diff_stat.dart';
import 'package:karmashala/src/features/explorer/presentation/checkout_row.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_row.dart';
import 'package:karmashala/src/features/explorer/presentation/project_card.dart';
import 'package:karmashala/src/features/explorer/presentation/session_card.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/window_matrix.dart';

/// The shell every Explorer row draws itself into.
///
/// Two complaints from the owner produced it, and both are asserted here:
///
/// * *"the cards are not separated properly"* — a row is a tile of its own
///   tone with a gap under it, at every depth and for every row kind.
/// * *"the menu button is not aligned properly … right click does that
///   already"* — one slot on every row kind, and on a pointer surface the
///   button inside it appears only when a pointer or the keyboard is on the
///   row. That is only honest while the menu stays reachable without a mouse,
///   so `Shift+F10` and the Menu key are asserted too.
void main() {
  const desktop = Size(1440, 900);
  const phone = Size(390, 844);

  List<PopupMenuEntry<String>> menu() => [
    DesktopMenuItem(
      value: 'rename',
      label: 'Rename',
      icon: AppIcons.pencilSimple,
    ),
  ];

  /// What the rows reported through `onMenu`.
  final picked = <String>[];

  /// One of each row kind, at the depth the Explorer draws it.
  Widget rows({bool selected = false}) => Column(
    children: [
      ProjectCard(
        name: 'popupbits',
        path: r'C:\Users\me\projects\popupbits',
        expanded: true,
        selected: false,
        summary: const ProjectSummary(sessions: 2),
        onTap: () {},
        onNewSession: () {},
        menuItems: menu(),
        onMenu: picked.add,
      ),
      CheckoutRow(
        depth: 1,
        icon: AppIcons.gitBranch,
        title: 'karmashala-app',
        expanded: true,
        onTap: () {},
        menuItems: menu(),
        onMenu: picked.add,
      ),
      SessionCard(
        depth: 2,
        selected: selected,
        agentIcon: AppIcons.playCircle,
        agentLabel: 'Claude Code  ·  running',
        title: 'Benchmark arcade games',
        onTap: () {},
        menuItems: menu(),
        onMenu: picked.add,
      ),
      SessionCard(
        depth: 3,
        selected: false,
        agentIcon: AppIcons.arrowBendDownRight,
        agentLabel: 'Claude Code  ·  running',
        title: 'A subagent of it',
        onTap: () {},
        menuItems: menu(),
        onMenu: picked.add,
      ),
    ],
  );

  Widget host(Widget child) => MaterialApp(
    theme: AppTheme.light(),
    // Exactly what a root does: measure the width, install the density.
    builder: (context, inner) => UiDensity.wrap(context, inner!),
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );

  Future<void> pump(
    WidgetTester tester, {
    Size size = desktop,
    bool selected = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    picked.clear();
    await tester.pumpWidget(host(rows(selected: selected)));
    await tester.pumpAndSettle();
  }

  /// The row's tile: the outermost decorated box inside it, which is the one
  /// [ExplorerRow] paints the tone, the state and the corners on.
  Finder tile(Finder row) =>
      find.descendant(of: row, matching: find.byType(DecoratedBox)).first;

  Color tileColor(WidgetTester tester, Finder row) {
    final box = tester.widget<DecoratedBox>(tile(row));
    return (box.decoration as BoxDecoration).color!;
  }

  Future<TestGesture> hover(WidgetTester tester, Finder finder) async {
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(() => gesture.removePointer());
    await gesture.moveTo(tester.getCenter(finder));
    await tester.pumpAndSettle();
    return gesture;
  }

  group('separation', () {
    testWidgets('every row kind draws its own tile, one step off the pane', (
      tester,
    ) async {
      await pump(tester);
      final surface = AppTheme.light().colorScheme.surface;

      final project = tileColor(tester, find.byType(ProjectCard));
      final checkout = tileColor(tester, find.byType(CheckoutRow));
      final session = tileColor(tester, find.byType(SessionCard).first);

      for (final color in [project, checkout, session]) {
        expect(
          color,
          isNot(surface),
          reason: 'a row painted in the pane colour has no edges',
        );
      }
      // And the tones differ from one another, so depth reads as tone as well
      // as position.
      expect({project, checkout, session}, hasLength(3));
    });

    testWidgets('consecutive rows do not touch', (tester) async {
      await pump(tester);
      final tiles = [
        tester.getRect(tile(find.byType(ProjectCard))),
        tester.getRect(tile(find.byType(CheckoutRow))),
        tester.getRect(tile(find.byType(SessionCard).first)),
        tester.getRect(tile(find.byType(SessionCard).last)),
      ];
      for (var i = 1; i < tiles.length; i++) {
        expect(
          tiles[i].top - tiles[i - 1].bottom,
          greaterThanOrEqualTo(ExplorerRow.gap),
          reason: 'row $i sits flush against the one above it',
        );
      }
    });

    testWidgets('depth is an indent of the tile, not only of the text', (
      tester,
    ) async {
      await pump(tester);
      final project = tester.getRect(tile(find.byType(ProjectCard))).left;
      final checkout = tester.getRect(tile(find.byType(CheckoutRow))).left;
      final session = tester
          .getRect(tile(find.byType(SessionCard).first))
          .left;
      final subagent = tester.getRect(tile(find.byType(SessionCard).last)).left;

      expect(checkout, greaterThan(project));
      expect(session, greaterThan(checkout));
      expect(subagent, greaterThan(session));
    });

    testWidgets('selection tints the tile and draws the accent rule', (
      tester,
    ) async {
      await pump(tester);
      final resting = tileColor(tester, find.byType(SessionCard).first);

      await pump(tester, selected: true);
      expect(tileColor(tester, find.byType(SessionCard).first), isNot(resting));

      final primary = AppTheme.light().colorScheme.primary;
      expect(
        find.descendant(
          of: find.byType(SessionCard).first,
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is Container &&
                widget.decoration is BoxDecoration &&
                (widget.decoration! as BoxDecoration).color == primary,
          ),
        ),
        findsOneWidget,
        reason: 'selection is carried by a rule in the accent',
      );
    });
  });

  group('the overflow menu', () {
    testWidgets('is not drawn on a pointer surface until it is wanted', (
      tester,
    ) async {
      await pump(tester);
      expect(find.byTooltip('Session actions'), findsNothing);
      expect(find.byTooltip('Project actions'), findsNothing);
      expect(find.byTooltip('Folder actions'), findsNothing);

      // The verb a row exists for stays put: only the overflow is on demand.
      expect(find.byTooltip('New session in this project'), findsOneWidget);
    });

    testWidgets('a pointer on the row reveals it, and leaving hides it again', (
      tester,
    ) async {
      await pump(tester);
      final card = find.byType(SessionCard).first;
      final gesture = await hover(tester, card);
      expect(find.byTooltip('Session actions'), findsOneWidget);
      // Only the row under the pointer: a hundred rows do not all light up.
      expect(find.byTooltip('Project actions'), findsNothing);

      await gesture.moveTo(Offset.zero);
      await tester.pumpAndSettle();
      expect(find.byTooltip('Session actions'), findsNothing);
    });

    testWidgets('the slot is reserved, so nothing reflows under the pointer', (
      tester,
    ) async {
      await pump(tester);
      final title = find.text('Benchmark arcade games');
      final before = tester.getRect(title);

      await hover(tester, find.byType(SessionCard).first);
      expect(tester.getRect(title), before);
    });

    testWidgets('a keyboard-focused row shows it without any pointer', (
      tester,
    ) async {
      await pump(tester);
      Focus.of(
        tester.element(find.text('Benchmark arcade games')),
      ).requestFocus();
      await tester.pumpAndSettle();

      expect(find.byTooltip('Session actions'), findsOneWidget);
    });

    testWidgets('Shift+F10 opens it from the focused row', (tester) async {
      await pump(tester);
      Focus.of(
        tester.element(find.text('Benchmark arcade games')),
      ).requestFocus();
      await tester.pumpAndSettle();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
      await tester.sendKeyEvent(LogicalKeyboardKey.f10);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
      await tester.pumpAndSettle();

      expect(find.text('Rename'), findsOneWidget);
    });

    testWidgets('so does the Menu key', (tester) async {
      await pump(tester);
      Focus.of(tester.element(find.text('karmashala-app'))).requestFocus();
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
      await tester.pumpAndSettle();

      expect(find.text('Rename'), findsOneWidget);
    });

    testWidgets('a right-click opens it, which is the desktop gesture', (
      tester,
    ) async {
      await pump(tester);
      await tester.tap(find.byType(SessionCard).first, buttons: kSecondaryButton);
      await tester.pumpAndSettle();

      expect(find.text('Rename'), findsOneWidget);
    });

    testWidgets('a choice made with the mouse actually reaches the row', (
      tester,
    ) async {
      // The bug this exists for: the button was drawn only while the row was
      // hovered, and opening the menu puts a modal barrier over the row — so
      // the button unmounted underneath its own menu and `showMenu` dropped
      // the result. Every menu choice was silently discarded for a mouse user,
      // while right-click and Shift+F10 kept working, which is why nothing
      // here caught it. Assert the *effect*, not that a menu appeared.
      await pump(tester);
      await hover(tester, find.byType(SessionCard).first);
      await tester.tap(find.byTooltip('Session actions'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();

      expect(picked, ['rename']);
    });

    testWidgets('and the button goes again once the menu is gone', (
      tester,
    ) async {
      await pump(tester);
      final gesture = await hover(tester, find.byType(SessionCard).first);
      await tester.tap(find.byTooltip('Session actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();

      await gesture.moveTo(Offset.zero);
      await tester.pumpAndSettle();
      expect(
        find.byTooltip('Session actions'),
        findsNothing,
        reason: 'latching it open must not leave it latched',
      );
    });

    testWidgets('a screen reader can reach it without a pointer', (
      tester,
    ) async {
      // Revealing the button on hover took the control out of the semantics
      // tree entirely: browse mode does not move Flutter's focus, so there was
      // no "Session actions" to find anywhere in the pane. The row carries the
      // menu as a custom action, in the same words the tooltip uses.
      final handle = tester.ensureSemantics();
      await pump(tester);

      // Walked from the root: a `Semantics` carrying only actions is merged
      // into a neighbouring node, so asking one widget's node is not the same
      // question as "can an assistive technology find this anywhere".
      final labels = <String>[];
      void visit(SemanticsNode node) {
        for (final id in node.getSemanticsData().customSemanticsActionIds ??
            const <int>[]) {
          final label = CustomSemanticsAction.getAction(id)?.label;
          if (label != null) labels.add(label);
        }
        node.visitChildren((child) {
          visit(child);
          return true;
        });
      }

      visit(tester.getSemantics(find.byType(MaterialApp)));

      expect(
        labels,
        containsAll(['Session actions', 'Project actions', 'Folder actions']),
        reason: 'every row kind offers its menu without a pointer',
      );
      handle.dispose();
    });

    testWidgets('a touch-width surface draws it at rest', (tester) async {
      // A thumb has neither a hover nor a right-click, so hiding it there would
      // put the menu out of reach entirely. Width, not the operating system.
      await pump(tester, size: phone);
      expect(find.byTooltip('Session actions'), findsWidgets);
      expect(find.byTooltip('Project actions'), findsOneWidget);
    });
  });

  group('at both form factors', () {
    for (final size in [desktop, phone]) {
      testWidgets('nothing overflows at ${size.width.toInt()}px', (
        tester,
      ) async {
        await pump(tester, size: size);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('the rows survive the window and accessibility matrix', (
      tester,
    ) async {
      await expectSurvivesWindowMatrix(
        tester,
        build: () => host(rows()),
        because: 'every row control keeps a name and stays reachable by Tab',
      );
    });
  });
}
