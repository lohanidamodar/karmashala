import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/karmashala_app.dart';
import 'package:karmashala/src/app/shell/app_shell.dart';
import 'package:karmashala/src/app/shell/activity_strip.dart';
import 'package:karmashala/src/app/shell/shell_shortcuts.dart';
import 'package:karmashala/src/app/shell/side_panel.dart';
import 'package:karmashala/src/app/shell/side_panel_state.dart';
import 'package:karmashala_ui/icons.dart';

import '../../features/terminal/fake_instance.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/shell_menu.dart';
import '../../support/test_machine.dart';
import 'package:agent_cli/process.dart';
import '../../support/fake_data_server.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

/// A window with no room for the side panel draws only its rail. Nothing may
/// then claim the panel is open: not the rail, the chord, the View menu, the
/// title bar toggle or the status bar.
void main() {
  late TestMachine db;
  late FakeDataServer server;
  late Override data;

  setUp(() async {
    commandKeyIsMeta = false;
    db = TestMachine();
    server = FakeDataServer()..runsOn(db);
    server.environmentRows.upsert(
      localHostEnvironment(FixedClock(testTime).nowUtc()),
    );
    data = await server.override();
  });
  tearDown(() {
    commandKeyIsMeta = false;
  });

  // The narrowest side-by-side width (840, d828821cd) with the sidebar open:
  // the panel cannot fit beside the workbench floor. Below it the panel is a
  // sheet, which has room.
  const narrow = Size(ShellWidth.mediumBelow, 700);
  const wide = Size(1440, 900);

  Future<ProviderContainer> pumpAt(WidgetTester tester, Size size) async {
    final container = fakeTerminalContainer(machine: db, data: data);
    addTearDown(container.dispose);
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

  test('the layout reports whether the panel fits', () {
    // What the row shares is the window less the activity strip.
    expect(
      ShellLayout.panelFits(
        available: narrow.width - kActivityStripWidth,
        explorerColumn: true,
      ),
      isFalse,
    );
    expect(
      ShellLayout.panelFits(
        available: wide.width - kActivityStripWidth,
        explorerColumn: true,
      ),
      isTrue,
    );
    expect(
      ShellLayout.panelFits(
        available: narrow.width - kActivityStripWidth,
        explorerColumn: false,
      ),
      isTrue,
    );
  });

  testWidgets('with no room the toggle says why, and opens nothing', (
    tester,
  ) async {
    final container = await pumpAt(tester, narrow);
    expect(find.byType(SidePanel), findsOneWidget);

    final toggle = tester
        .widgetList<Tooltip>(find.byType(Tooltip))
        .map((t) => t.message ?? '')
        .where((m) => m.startsWith('Show or hide the side panel'));
    expect(toggle.single, contains('Widen the window to open the side panel'));

    container.read(sidePanelProvider.notifier).expand();
    await tester.pumpAndSettle();
    expect(container.read(sidePanelProvider), isNull);
    expect(container.read(visibleSidePanelProvider), isNull);
  });

  testWidgets('the chord and the View menu do not open it either', (
    tester,
  ) async {
    final container = await pumpAt(tester, narrow);
    container.read(sidePanelProvider.notifier).collapse();
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(container.read(sidePanelProvider), isNull);

    // The menus are behind the title bar's one glyph (5c1fe3f58).
    await openShellMenu(tester, 'View');
    // The toggle says why, is not ticked, and does nothing.
    final row = find.ancestor(
      of: find.text('Context panel  ·  $kSidePanelNoRoom'),
      matching: find.byType(MenuItemButton),
    );
    final item = tester.widget<MenuItemButton>(row);
    expect(item.onPressed, isNull, reason: 'disabled while there is no room');
    expect(
      find.descendant(of: row, matching: find.byIcon(AppIcons.check)),
      findsNothing,
      reason: 'the menu must not say the panel is open',
    );
    final surfaceItem = tester.widget<MenuItemButton>(
      find.ancestor(
        of: find.text('Files'),
        matching: find.byType(MenuItemButton),
      ),
    );
    expect(surfaceItem.onPressed, isNull);
  });

  testWidgets('a panel hidden by width comes back when the window widens', (
    tester,
  ) async {
    final container = await pumpAt(tester, wide);
    container.read(sidePanelProvider.notifier).select(SidePanelSurface.todos);
    await tester.pumpAndSettle();

    tester.view.physicalSize = narrow;
    await tester.pumpAndSettle();
    expect(container.read(visibleSidePanelProvider), isNull);
    expect(find.byType(ContextTabs), findsNothing);

    tester.view.physicalSize = wide;
    await tester.pumpAndSettle();
    expect(container.read(visibleSidePanelProvider), SidePanelSurface.todos);
  });
}
