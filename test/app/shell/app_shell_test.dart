import 'package:karmashala/src/app/karmashala_app.dart';
import 'package:karmashala/src/app/shell/app_shell.dart';
import 'package:karmashala/src/app/shell/quick_open/quick_open.dart';
import 'package:karmashala/src/app/shell/shell_shortcuts.dart';
import 'package:karmashala/src/app/shell/shell_state.dart';
import 'package:karmashala/src/app/shell/side_panel.dart';
import 'package:karmashala/src/app/shell/side_panel_state.dart';
import 'package:karmashala/src/app/shell/status_bar.dart';
import 'package:karmashala/src/app/shell/workbench.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_panel.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../features/terminal/fake_instance.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.memory();
    ensureLocalEnvironment(ExecutionEnvironmentDao(db), FixedClock(testTime));
  });
  tearDown(() => db.close());

  /// The shell hosts real terminals, so it needs the fake instance factory as
  /// well as a database — otherwise the workbench's first frame spawns a PTY.
  ProviderContainer shellContainer() {
    final container = fakeTerminalContainer(database: db);
    addTearDown(container.dispose);
    return container;
  }

  Future<ProviderContainer> pumpApp(
    WidgetTester tester, {
    required Size size,
  }) async {
    final container = shellContainer();
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const KarmashalaApp(),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('the wide layout is Explorer, workbench and the side panel', (
    tester,
  ) async {
    await pumpApp(tester, size: const Size(1440, 900));

    // One chrome row at the top, the tab strip's own height (no app icon or
    // name — the OS title bar carries those).
    expect(find.byType(ShellTitleBar), findsOneWidget);
    expect(tester.getSize(find.byType(ShellTitleBar)).height, Chrome.titleBar);
    expect(find.text('EXPLORER'), findsOneWidget);
    // The terminal is the content area now, not a dock under it.
    expect(find.byType(WorkbenchView), findsOneWidget);
    expect(find.byType(SidePanel), findsOneWidget);
    expect(find.byType(ShellStatusBar), findsOneWidget);
    // The Explorer sits to the left of the workbench, which sits to the left of
    // the side panel — the whole point of the move.
    final explorer = tester.getTopLeft(find.byType(ExplorerPanel)).dx;
    final workbench = tester.getTopLeft(find.byType(WorkbenchView)).dx;
    final panel = tester.getTopLeft(find.byType(SidePanel)).dx;
    expect(explorer, lessThan(workbench));
    expect(workbench, lessThan(panel));
  });

  testWidgets('the workbench takes the height a dock used to leave it', (
    tester,
  ) async {
    await pumpApp(tester, size: const Size(1440, 900));

    final body = tester.getSize(find.byType(WorkbenchView)).height;
    // The old dock was 280px of a ~850px body. Anything that still reserved a
    // dock's worth of space below the workbench would fail this.
    expect(body, greaterThan(700));
  });

  testWidgets('every side-panel surface is reachable from the rail', (
    tester,
  ) async {
    final container = await pumpApp(tester, size: const Size(1440, 900));

    for (final surface in SidePanelSurface.values) {
      expect(
        find.bySemanticsLabel(surface.label),
        findsAtLeastNWidgets(1),
        reason: '${surface.label} must not be stranded by the rail',
      );
    }
    expect(container.read(sidePanelProvider), SidePanelSurface.changes);
  });

  testWidgets('every rail glyph teaches its name and the key that reaches it', (
    tester,
  ) async {
    // Eight unlabelled glyphs in a 34px column. Hovering one has to be worth
    // something, and the thing worth teaching is the chord — a rail you have
    // to go to with the mouse every time is a rail you stop using.
    await pumpApp(tester, size: const Size(1440, 900));

    for (final surface in SidePanelSurface.values) {
      final tooltips = tester
          .widgetList<Tooltip>(find.byType(Tooltip))
          .map((t) => t.message ?? '')
          .where((m) => m.startsWith(surface.label));
      expect(
        tooltips,
        isNotEmpty,
        reason: '${surface.label} has no tooltip naming it',
      );
      expect(
        tooltips.first,
        contains(shellChordLabel<ToggleSidePanelIntent>()!),
        reason: '${surface.label} does not say how to reach it',
      );
    }

    // And the inbox, which has a chord of its own, says that one too.
    final inbox = tester
        .widgetList<Tooltip>(find.byType(Tooltip))
        .map((t) => t.message ?? '')
        .firstWhere((m) => m.startsWith(SidePanelSurface.inbox.label));
    expect(inbox, contains(shellChordLabel<OpenAttentionInboxIntent>()!));
  });

  testWidgets('the side panel keeps only its rail when collapsed', (
    tester,
  ) async {
    final container = await pumpApp(tester, size: const Size(1440, 900));

    final open = tester.getSize(find.byType(SidePanel)).width;
    container.read(sidePanelProvider.notifier).collapse();
    await tester.pumpAndSettle();
    final collapsed = tester.getSize(find.byType(SidePanel)).width;

    expect(collapsed, lessThan(open));
    expect(
      collapsed,
      lessThanOrEqualTo(40),
      reason: 'a collapsed panel must not hold fixed space',
    );

    // And it comes back to the surface it was showing, not to the first one.
    container.read(sidePanelProvider.notifier).select(SidePanelSurface.browser);
    container.read(sidePanelProvider.notifier).collapse();
    container.read(sidePanelProvider.notifier).expand();
    expect(container.read(sidePanelProvider), SidePanelSurface.browser);
  });

  testWidgets('focus mode gives the workbench the window', (tester) async {
    final container = await pumpApp(tester, size: const Size(1440, 900));

    final normal = tester.getSize(find.byType(WorkbenchView)).width;
    container.read(terminalMaximizedProvider.notifier).toggle();
    await tester.pumpAndSettle();

    expect(find.byType(ExplorerPanel), findsNothing);
    expect(find.byType(SidePanel), findsNothing);
    expect(
      tester.getSize(find.byType(WorkbenchView)).width,
      greaterThan(normal),
    );
  });

  testWidgets('narrow layout shows a single pane with a selector', (
    tester,
  ) async {
    final container = await pumpApp(tester, size: const Size(640, 900));

    expect(find.byType(ShellTitleBar), findsOneWidget);
    expect(find.byType(SegmentedButton<ShellPane>), findsOneWidget);
    // Explorer first, workbench on request — one pane at a time.
    expect(find.byType(ExplorerPanel), findsOneWidget);
    expect(find.byType(WorkbenchView), findsNothing);

    container
        .read(shellControllerProvider.notifier)
        .focusPane(ShellPane.detail);
    await tester.pumpAndSettle();
    expect(find.byType(ExplorerPanel), findsNothing);
    expect(find.byType(WorkbenchView), findsOneWidget);
    // The tools stay reachable at this width: the rail is all the panel keeps.
    expect(find.byType(SidePanel), findsOneWidget);
  });

  testWidgets('ShellWidth names the three breakpoints', (tester) async {
    expect(ShellWidth.of(390), ShellWidth.compact);
    expect(ShellWidth.of(759), ShellWidth.compact);
    expect(ShellWidth.of(760), ShellWidth.medium);
    expect(ShellWidth.of(1179), ShellWidth.medium);
    expect(ShellWidth.of(1440), ShellWidth.expanded);
  });

  testWidgets('a summon request from outside the tree opens quick open', (
    tester,
  ) async {
    // What the global hotkey now does. `SystemIntegrationService` has no
    // BuildContext — it registers the hotkey from outside the widget tree —
    // so it bumps this counter and the shell, which has a Navigator above it,
    // puts the palette up. Before this the same hotkey opened a second window.
    final container = await pumpApp(tester, size: const Size(1440, 900));
    expect(find.byType(QuickOpen), findsNothing);

    container.read(quickOpenRequestProvider.notifier).bump();
    await tester.pumpAndSettle();

    expect(find.byType(QuickOpen), findsOneWidget);
  });
}
