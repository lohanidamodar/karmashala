import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/karmashala_app.dart';
import 'package:karmashala/src/app/shell/app_shell.dart';
import 'package:karmashala/src/app/shell/shell_shortcuts.dart';
import 'package:karmashala/src/app/shell/side_panel.dart';
import 'package:karmashala/src/app/shell/side_panel_state.dart';

import '../../features/terminal/fake_instance.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
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

  // Medium width with the Explorer open: the panel cannot fit beside the
  // workbench floor.
  const narrow = Size(800, 700);
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
    expect(
      ShellLayout.panelFits(available: narrow.width, explorerColumn: true),
      isFalse,
    );
    expect(
      ShellLayout.panelFits(available: wide.width, explorerColumn: true),
      isTrue,
    );
    expect(
      ShellLayout.panelFits(available: narrow.width, explorerColumn: false),
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
    await tester.sendKeyEvent(LogicalKeyboardKey.digit3);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(container.read(sidePanelProvider), isNull);

    await tester.tap(find.text('View'));
    await tester.pumpAndSettle();
    final item = tester.widget<CheckboxMenuButton>(
      find.byType(CheckboxMenuButton).at(1),
    );
    expect(item.value, isFalse);
    expect(item.onChanged, isNull, reason: 'disabled while there is no room');
    expect(
      find.textContaining('Widen the window to open the side panel'),
      findsOneWidget,
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
