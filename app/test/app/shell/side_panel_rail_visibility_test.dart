import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/karmashala_app.dart';
import 'package:karmashala/src/app/shell/shell_shortcuts.dart';
import 'package:karmashala/src/app/shell/side_panel.dart';
import 'package:karmashala/src/app/shell/side_panel_state.dart';
import 'package:karmashala/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/notifications/application/attention_inbox.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/data/settings_repository.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala_ui/icons.dart';

import '../../features/terminal/fake_instance.dart';
import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// Hiding surfaces from the side panel's rail, the way VS Code's activity bar
/// does it: a right-click lists every surface with a check, a hidden one stays
/// reachable everywhere else, and opening it puts its glyph back while open.
void main() {
  late AppDatabase db;
  late FakeDataServer server;

  setUp(() {
    commandKeyIsMeta = false;
    server = FakeDataServer();
    db = AppDatabase.memory();
    ensureLocalEnvironment(ExecutionEnvironmentDao(db), FixedClock(testTime));
  });
  tearDown(() {
    commandKeyIsMeta = false;
    db.close();
  });

  const wide = Size(1440, 900);
  const narrow = Size(800, 700);

  Future<ProviderContainer> pumpApp(
    WidgetTester tester, {
    Size size = wide,
    List<String> hidden = const [],
    int attention = 0,
  }) async {
    final data = await server.override();
    final container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        data,
        attentionCountProvider.overrideWith((ref) => ref.watch(_attention)),
      ],
    );
    addTearDown(container.dispose);
    container.read(_attention.notifier).set(attention);
    final settings = container.read(settingsControllerProvider.notifier);
    for (final id in hidden) {
      settings.setSidePanelSurfaceHidden(id, hidden: true);
    }
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const KarmashalaApp(),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  Finder glyph(String label) => find.descendant(
    of: find.byType(SidePanel),
    matching: find.byWidgetPredicate(
      (w) => w is Semantics && w.properties.label == label,
    ),
  );

  List<String> stored() =>
      SettingsRepository(server.store).load().hiddenSidePanelSurfaces;

  Finder checkRow(String label) => find.ancestor(
    of: find.text(label),
    matching: find.byWidgetPredicate((w) => w is PopupMenuItem),
  );

  bool isChecked(WidgetTester tester, String label) {
    final row = checkRow(label);
    expect(row, findsOneWidget, reason: '$label is not in the menu');
    return tester.any(
      find.descendant(of: row, matching: find.byIcon(AppIcons.check)),
    );
  }

  /// A right-click on the rail below its last glyph.
  Future<void> rightClickRail(WidgetTester tester) async {
    final panel = tester.getRect(find.byType(SidePanel));
    await tester.tapAt(
      Offset(panel.right - 17, panel.bottom - 12),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
  }

  group('the rule', () {
    test('a stored id names a surface, or nothing', () {
      expect(SidePanelSurface.fromId('media'), SidePanelSurface.media);
      expect(SidePanelSurface.fromId('fromANewerBuild'), isNull);
    });

    test('hidden is off the rail unless open, or an Inbox that needs you', () {
      const hidden = {SidePanelSurface.media, SidePanelSurface.inbox};
      expect(SidePanelSurface.plan.showsOnRail(hidden: hidden), isTrue);
      expect(SidePanelSurface.media.showsOnRail(hidden: hidden), isFalse);
      expect(
        SidePanelSurface.media.showsOnRail(
          hidden: hidden,
          open: SidePanelSurface.media,
        ),
        isTrue,
      );
      expect(SidePanelSurface.inbox.showsOnRail(hidden: hidden), isFalse);
      expect(
        SidePanelSurface.inbox.showsOnRail(hidden: hidden, needsYou: true),
        isTrue,
      );
      expect(
        SidePanelSurface.media.showsOnRail(hidden: hidden, needsYou: true),
        isFalse,
      );
    });

    test('the hidden set ignores ids this build does not have', () async {
      server.store.write(
        'settings.v1',
        '{"hiddenSidePanelSurfaces":["plan","fromANewerBuild"]}',
      );
      final container = ProviderContainer(
        overrides: [
          ...fakeTerminalOverrides(database: db),
          await server.override(),
        ],
      );
      addTearDown(container.dispose);
      expect(container.read(hiddenSidePanelSurfacesProvider), {
        SidePanelSurface.plan,
      });
    });
  });

  group('the rail menu', () {
    testWidgets('right-clicking a glyph offers to hide that one', (
      tester,
    ) async {
      await pumpApp(tester);
      expect(glyph('Media'), findsOneWidget);

      await tester.tap(glyph('Media'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(find.text("Hide 'Media'"), findsOneWidget);
      // One menu, not one per nested region.
      expect(find.text('Show all'), findsOneWidget);

      await tester.tap(find.text("Hide 'Media'"));
      await tester.pumpAndSettle();
      expect(glyph('Media'), findsNothing);
      expect(stored(), ['media']);
    });

    testWidgets('right-clicking the rail lists every surface, checked', (
      tester,
    ) async {
      await pumpApp(tester, hidden: ['plan']);
      expect(glyph('Plan'), findsNothing);

      await rightClickRail(tester);
      expect(find.textContaining("Hide '"), findsNothing);
      for (final surface in SidePanelSurface.offered(debugMode: true)) {
        if (!tester.any(checkRow(surface.label))) {
          // Logs is offered only in debug mode, which the build may not be.
          expect(surface, SidePanelSurface.logs);
          continue;
        }
        expect(
          isChecked(tester, surface.label),
          surface != SidePanelSurface.plan,
          reason: surface.label,
        );
      }

      await tester.tap(checkRow('Plan'));
      await tester.pumpAndSettle();
      expect(glyph('Plan'), findsOneWidget);
      expect(stored(), isEmpty);

      await rightClickRail(tester);
      await tester.tap(checkRow('Todos'));
      await tester.pumpAndSettle();
      expect(glyph('Todos'), findsNothing);
      expect(stored(), ['todos']);
    });

    testWidgets('Show all puts every hidden surface back', (tester) async {
      await pumpApp(tester, hidden: ['plan', 'media', 'todos']);
      await rightClickRail(tester);
      await tester.tap(find.text('Show all'));
      await tester.pumpAndSettle();
      expect(stored(), isEmpty);
      for (final label in ['Plan', 'Media', 'Todos']) {
        expect(glyph(label), findsOneWidget, reason: label);
      }
    });

    testWidgets(
      'the rail\'s own button opens the same menu from the keyboard',
      (tester) async {
        await pumpApp(tester, hidden: ['plan']);
        final button = glyph('Side panel items');
        expect(button, findsOneWidget);

        // The InkWell's own focus node: the nearest one above its glyph.
        Focus.of(
          tester.element(
            find.descendant(of: button, matching: find.byType(Icon)),
          ),
        ).requestFocus();
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();

        expect(isChecked(tester, 'Plan'), isFalse);
        expect(isChecked(tester, 'Media'), isTrue);
      },
    );

    testWidgets(
      'with no room the glyphs are disabled and the menu still works',
      (tester) async {
        final container = await pumpApp(tester, size: narrow);
        expect(container.read(visibleSidePanelProvider), isNull);
        expect(
          tester.widget<Semantics>(glyph('Media')).properties.enabled,
          isFalse,
        );

        await tester.tap(glyph('Media'), buttons: kSecondaryButton);
        await tester.pumpAndSettle();
        await tester.tap(find.text("Hide 'Media'"));
        await tester.pumpAndSettle();
        expect(glyph('Media'), findsNothing);
        expect(container.read(visibleSidePanelProvider), isNull);
      },
    );
  });

  group('a hidden surface', () {
    testWidgets('opens from the View menu and wears a glyph while open', (
      tester,
    ) async {
      final container = await pumpApp(tester, hidden: ['media']);
      expect(glyph('Media'), findsNothing);

      await tester.tap(find.text('View'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.ancestor(
          of: find.text('Media'),
          matching: find.byType(MenuItemButton),
        ),
      );
      await tester.pumpAndSettle();

      expect(container.read(visibleSidePanelProvider), SidePanelSurface.media);
      expect(glyph('Media'), findsOneWidget);
      expect(
        tester.widget<Semantics>(glyph('Media')).properties.selected,
        isTrue,
      );
      expect(stored(), ['media'], reason: 'opening it does not unhide it');

      // Its own glyph closes it, and the glyph goes with it.
      await tester.tap(glyph('Media'));
      await tester.pumpAndSettle();
      expect(container.read(visibleSidePanelProvider), isNull);
      expect(glyph('Media'), findsNothing);
    });

    testWidgets('opens from quick open', (tester) async {
      final container = await pumpApp(tester, hidden: ['media']);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '>Media');
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(container.read(visibleSidePanelProvider), SidePanelSurface.media);
      expect(glyph('Media'), findsOneWidget);
    });

    testWidgets('opens from its chord', (tester) async {
      final container = await pumpApp(tester, hidden: ['inbox']);
      expect(glyph('Inbox'), findsNothing);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      expect(container.read(visibleSidePanelProvider), SidePanelSurface.inbox);
      expect(glyph('Inbox'), findsOneWidget);
    });

    testWidgets('hiding the open surface leaves it open until it is closed', (
      tester,
    ) async {
      final container = await pumpApp(tester);
      container.read(sidePanelProvider.notifier).select(SidePanelSurface.todos);
      await tester.pumpAndSettle();

      await tester.tap(glyph('Todos'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text("Hide 'Todos'"));
      await tester.pumpAndSettle();

      expect(container.read(visibleSidePanelProvider), SidePanelSurface.todos);
      expect(glyph('Todos'), findsOneWidget);

      container.read(sidePanelProvider.notifier).collapse();
      await tester.pumpAndSettle();
      expect(glyph('Todos'), findsNothing);
    });

    testWidgets('a temporary glyph offers to keep it on the rail', (
      tester,
    ) async {
      final container = await pumpApp(tester, hidden: ['media']);
      container.read(sidePanelProvider.notifier).select(SidePanelSurface.media);
      await tester.pumpAndSettle();

      await tester.tap(glyph('Media'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(find.text("Hide 'Media'"), findsNothing);
      await tester.tap(find.text("Keep 'Media' on the rail"));
      await tester.pumpAndSettle();
      expect(stored(), isEmpty);

      container.read(sidePanelProvider.notifier).collapse();
      await tester.pumpAndSettle();
      expect(glyph('Media'), findsOneWidget);
    });

    testWidgets('a hidden Inbox shows its glyph while something needs you', (
      tester,
    ) async {
      final container = await pumpApp(tester, hidden: ['inbox']);
      expect(glyph('Inbox'), findsNothing);

      container.read(_attention.notifier).set(2);
      await tester.pumpAndSettle();
      expect(glyph('Inbox'), findsOneWidget);
      expect(find.text('2 need you'), findsOneWidget);

      // The status bar's way in still works, whatever the rail shows.
      await tester.tap(find.text('2 need you'));
      await tester.pumpAndSettle();
      expect(container.read(visibleSidePanelProvider), SidePanelSurface.inbox);

      container.read(sidePanelProvider.notifier).collapse();
      container.read(_attention.notifier).set(0);
      await tester.pumpAndSettle();
      expect(glyph('Inbox'), findsNothing);
    });
  });

  testWidgets('everything can be hidden; the panel still opens', (
    tester,
  ) async {
    final container = await pumpApp(
      tester,
      hidden: [for (final s in SidePanelSurface.values) s.name],
    );
    container.read(sidePanelProvider.notifier).collapse();
    await tester.pumpAndSettle();
    for (final surface in SidePanelSurface.values) {
      expect(glyph(surface.label), findsNothing, reason: surface.label);
    }
    // The way back is still on the rail.
    expect(glyph('Side panel items'), findsOneWidget);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit3);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    final open = container.read(visibleSidePanelProvider);
    expect(open, isNotNull);
    expect(glyph(open!.label), findsOneWidget);
  });

  group('the View menu', () {
    Future<void> openSubmenu(WidgetTester tester) async {
      await tester.tap(find.text('View'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Side panel items'));
      await tester.pumpAndSettle();
    }

    CheckboxMenuButton item(WidgetTester tester, String label) =>
        tester.widget<CheckboxMenuButton>(
          find.ancestor(
            of: find.text(label),
            matching: find.byType(CheckboxMenuButton),
          ),
        );

    testWidgets('lists every surface with a check, and toggles one', (
      tester,
    ) async {
      await pumpApp(tester, hidden: ['plan']);
      await openSubmenu(tester);
      expect(item(tester, 'Plan').value, isFalse);
      expect(item(tester, 'Media').value, isTrue);

      await tester.tap(find.widgetWithText(CheckboxMenuButton, 'Media'));
      await tester.pumpAndSettle();
      expect(stored(), ['media', 'plan']);
      expect(glyph('Media'), findsNothing);

      await openSubmenu(tester);
      await tester.tap(find.widgetWithText(CheckboxMenuButton, 'Plan'));
      await tester.pumpAndSettle();
      expect(stored(), ['media']);
      expect(glyph('Plan'), findsOneWidget);
    });

    testWidgets('Show all is there, and disabled when nothing is hidden', (
      tester,
    ) async {
      await pumpApp(tester);
      await openSubmenu(tester);
      final showAll = tester.widget<MenuItemButton>(
        find.widgetWithText(MenuItemButton, 'Show all'),
      );
      expect(showAll.onPressed, isNull);
    });
  });

  testWidgets('toggling a surface redraws the rail, not the panel', (
    tester,
  ) async {
    final container = await pumpApp(tester);
    container.read(sidePanelProvider.notifier).select(SidePanelSurface.todos);
    await tester.pumpAndSettle();

    final builds = <String, int>{};
    debugOnRebuildDirtyWidget = (element, _) {
      final name = element.widget.runtimeType.toString();
      builds[name] = (builds[name] ?? 0) + 1;
    };
    addTearDown(() => debugOnRebuildDirtyWidget = null);

    container
        .read(settingsControllerProvider.notifier)
        .setSidePanelSurfaceHidden('media', hidden: true);
    await tester.pumpAndSettle();
    debugOnRebuildDirtyWidget = null;

    expect(glyph('Media'), findsNothing, reason: 'the toggle took effect');
    expect(
      builds['_SidePanelRail'],
      1,
      reason: 'the counter saw the rail redraw, once: $builds',
    );
    for (final type in const [
      'SidePanel',
      '_SidePanelBody',
      'TodosView',
      'WorkbenchView',
      'ShellStatusBar',
      'AppShell',
    ]) {
      expect(builds[type], isNull, reason: '$type rebuilt: $builds');
    }
  });
}

final _attention = NotifierProvider<_Attention, int>(_Attention.new);

class _Attention extends Notifier<int> {
  @override
  int build() => 0;

  void set(int value) => state = value;
}
