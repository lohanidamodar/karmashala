import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/karmashala_app.dart';
import 'package:karmashala/src/app/shell/shell_shortcuts.dart';
import 'package:karmashala/src/app/shell/side_panel.dart';
import 'package:karmashala/src/app/shell/side_panel_state.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/data/settings_repository.dart';

import '../../features/terminal/fake_instance.dart';
import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/shell_menu.dart';
import 'package:agent_cli/process.dart';
import '../../support/test_machine.dart';

/// **The context panel** (UI overhaul spec §6): closed by default, tabs for
/// Changes, Repo, History and Files, and More for every other surface. A
/// surface the user took out of More is still reachable from the View menu and
/// quick open.
void main() {
  late TestMachine db;
  late FakeDataServer server;

  setUp(() {
    commandKeyIsMeta = false;
    server = FakeDataServer();
    db = TestMachine();
    server.environmentRows.upsert(
      localHostEnvironment(FixedClock(testTime).nowUtc()),
    );
  });
  tearDown(() {
    commandKeyIsMeta = false;
  });

  const wide = Size(1440, 900);

  Future<ProviderContainer> pumpApp(
    WidgetTester tester, {
    List<String> hidden = const [],
  }) async {
    final data = await server.override();
    final container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(machine: db),
        data,
      ],
    );
    addTearDown(container.dispose);
    final settings = container.read(settingsControllerProvider.notifier);
    for (final id in hidden) {
      settings.setSidePanelSurfaceHidden(id, hidden: true);
    }
    tester.view.physicalSize = wide;
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

  List<String> stored() =>
      SettingsRepository(server.store).load().hiddenSidePanelSurfaces;

  Finder tab(String label) => find.descendant(
    of: find.byType(ContextTabs),
    matching: find.bySemanticsLabel(label),
  );

  // By what it says to a reader: where the labels do not fit (the test font
  // is twice the shipped one's width) every tab is its glyph alone.
  Future<void> openMore(WidgetTester tester) async {
    await tester.tap(tab('More ▾'));
    await tester.pumpAndSettle();
  }

  Finder menuRow(String label) => find.ancestor(
    of: find.text(label),
    matching: find.byWidgetPredicate((w) => w is PopupMenuItem),
  );

  group('the rule', () {
    test('a stored id names a surface, or nothing', () {
      expect(SidePanelSurface.fromId('media'), SidePanelSurface.media);
      expect(SidePanelSurface.fromId('fromANewerBuild'), isNull);
    });

    test('four tabs hold their surfaces; everything else is More', () {
      expect(ContextTab.of(SidePanelSurface.changes), ContextTab.changes);
      expect(ContextTab.of(SidePanelSurface.repository), ContextTab.repo);
      expect(ContextTab.of(SidePanelSurface.checkpoints), ContextTab.history);
      for (final surface in SidePanelSurface.values) {
        final tab = ContextTab.of(surface);
        expect(tab.surfaces.isEmpty || tab.surfaces.contains(surface), isTrue);
      }
      expect(ContextTab.of(SidePanelSurface.decisions), ContextTab.history);
      expect(ContextTab.of(SidePanelSurface.plan), ContextTab.history);
      expect(ContextTab.of(SidePanelSurface.files), ContextTab.files);
      expect(ContextTab.of(SidePanelSurface.todos), ContextTab.more);
    });

    test('the hidden set ignores ids this build does not have', () async {
      server.store.write(
        'settings.v1',
        '{"hiddenSidePanelSurfaces":["plan","fromANewerBuild"]}',
      );
      final container = ProviderContainer(
        overrides: [
          ...fakeTerminalOverrides(machine: db),
          await server.override(),
        ],
      );
      addTearDown(container.dispose);
      expect(container.read(hiddenSidePanelSurfacesProvider), {
        SidePanelSurface.plan,
      });
    });
  });

  testWidgets('closed by default; the toggle opens it on Changes', (
    tester,
  ) async {
    final container = await pumpApp(tester);
    expect(container.read(sidePanelProvider), isNull);
    expect(find.byType(ContextTabs), findsNothing);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(container.read(visibleSidePanelProvider), SidePanelSurface.changes);
    for (final label in ['Changes', 'Repo', 'History', 'Files']) {
      expect(tab(label), findsOneWidget, reason: '$label is not a tab');
    }
    expect(tab('More ▾'), findsOneWidget);
  });

  testWidgets('a tab shows its surface, and stays open when pressed again', (
    tester,
  ) async {
    final container = await pumpApp(tester);
    container.read(sidePanelProvider.notifier).expand();
    await tester.pumpAndSettle();

    await tester.tap(tab('Repo'));
    await tester.pumpAndSettle();
    expect(
      container.read(visibleSidePanelProvider),
      SidePanelSurface.repository,
    );

    await tester.tap(tab('History'));
    await tester.pumpAndSettle();
    expect(
      container.read(visibleSidePanelProvider),
      SidePanelSurface.checkpoints,
    );

    await tester.tap(tab('History'));
    await tester.pumpAndSettle();
    expect(
      container.read(visibleSidePanelProvider),
      SidePanelSurface.checkpoints,
      reason: 'a tab never closes the panel',
    );
  });

  testWidgets('More lists the rest, and keeps its own name', (tester) async {
    final container = await pumpApp(tester);
    container.read(sidePanelProvider.notifier).expand();
    await tester.pumpAndSettle();

    await openMore(tester);
    for (final label in ['Todos', 'Media', 'Notes']) {
      expect(menuRow(label), findsOneWidget, reason: '$label is not in More');
    }
    expect(menuRow('Repository'), findsNothing, reason: 'Repo is a tab');
    expect(menuRow('Plan'), findsNothing, reason: 'Plan is under History');
    await tester.tap(menuRow('Todos'));
    await tester.pumpAndSettle();

    expect(container.read(visibleSidePanelProvider), SidePanelSurface.todos);
    expect(tab('More ▾'), findsOneWidget);

    // Back to Changes, then More again goes to the one it showed last.
    await tester.tap(tab('Changes'));
    await tester.pumpAndSettle();
    container.read(sidePanelProvider.notifier).showTab(ContextTab.more);
    await tester.pumpAndSettle();
    expect(container.read(visibleSidePanelProvider), SidePanelSurface.todos);
  });

  group('a surface taken out of More', () {
    testWidgets('is not listed, unless it is the one showing', (tester) async {
      final container = await pumpApp(tester, hidden: ['media']);
      container.read(sidePanelProvider.notifier).expand();
      await tester.pumpAndSettle();

      await openMore(tester);
      expect(menuRow('Media'), findsNothing);
      await tester.tapAt(Offset.zero);
      await tester.pumpAndSettle();

      container.read(sidePanelProvider.notifier).show(SidePanelSurface.media);
      await tester.pumpAndSettle();
      await openMore(tester);
      expect(menuRow('Media'), findsOneWidget);
    });

    testWidgets('still opens from the View menu', (tester) async {
      final container = await pumpApp(tester, hidden: ['media']);

      // The menus are behind the title bar's one glyph (5c1fe3f58).
      await openShellMenu(tester, 'View');
      await tester.tap(find.text('More'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.ancestor(
          of: find.text('Media'),
          matching: find.byType(MenuItemButton),
        ),
      );
      await tester.pumpAndSettle();

      expect(container.read(visibleSidePanelProvider), SidePanelSurface.media);
      expect(stored(), ['media'], reason: 'opening it does not unhide it');
      // More says what it is, never the open panel's name (8e59e76f6).
      expect(tab('More ▾'), findsOneWidget);
    });

    testWidgets('still opens from quick open', (tester) async {
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
    });
  });
}
