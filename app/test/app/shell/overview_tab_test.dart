import 'dart:async';
import 'dart:io';

import 'package:agent_cli/process.dart' show localHostEnvironment;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/karmashala_app.dart';
import 'package:karmashala/src/app/shell/quick_open/quick_open.dart';
import 'package:karmashala/src/app/shell/activity_strip.dart';
import 'package:karmashala/src/app/shell/shell_shortcuts.dart';
import 'package:karmashala/src/features/terminal/presentation/terminal_panel.dart'
    show TerminalTabChip;
import 'package:karmashala/src/app/shell/workbench.dart';
import 'package:karmashala/src/core/logging/server_log_tail.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/features/overview/application/overview_prefs.dart';
import 'package:karmashala/src/features/overview/presentation/overview_tab_view.dart';
import 'package:karmashala/src/features/overview/timeline/presentation/overview_timeline_view.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/geometry.dart';

import '../../features/scale/scale_harness.dart';
import '../../features/terminal/fake_instance.dart';
import '../../support/fake_command_runner.dart';
import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// **The Overview is a workbench tab**, opened the way Usage and Logs are:
/// one tab however often it is asked for, from quick open, its chord and the
/// activity strip.
void main() {
  late CountingLayoutStore db;
  late FakeDataServer server;
  late Override data;
  // Made outside the widget tests: real I/O never completes in their fake time.
  late Directory dir;
  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('ks-overview-tab');
  });
  tearDownAll(() => dir.delete(recursive: true));

  setUp(() async {
    db = CountingLayoutStore();
    server = FakeDataServer();
    data = await server.override();
    server.environmentRows.upsert(
      localHostEnvironment(FixedClock(testTime).nowUtc()),
    );
  });
  tearDown(() => db.close());

  Future<ProviderContainer> launch(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final container = ProviderContainer(
      overrides: [
        data,
        ...fakeTerminalOverrides(layoutStore: db),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(fallback: FakeCommandRunner()),
        ),
        hostCommandRunnerProvider.overrideWithValue(FakeCommandRunner()),
        serverLogTailProvider.overrideWithValue(null),
        overviewPrefsDirectoryProvider.overrideWithValue(() async => dir),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const KarmashalaApp(),
      ),
    );
    // Bounded pumps: a terminal cursor blinks for ever.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 200));
    return container;
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
  }

  WidgetRef refOf(WidgetTester tester) =>
      tester.element(find.byType(WorkbenchView)) as WidgetRef;

  List<String> overviewTabsIn(ProviderContainer container) => [
    for (final tab in container.read(terminalSessionsControllerProvider).tabs)
      if (tab.layout.panes.any(isOverviewPane)) tab.id,
  ];

  testWidgets('opens one tab, and opening it again focuses that one', (
    tester,
  ) async {
    final container = await launch(tester);

    openOverviewTab(refOf(tester));
    await settle(tester);

    expect(find.byType(OverviewTabView), findsOneWidget);
    final tabId = overviewTabsIn(container).single;
    final controller = container.read(
      terminalSessionsControllerProvider.notifier,
    );
    expect(controller.titleForTab(tabId), 'Agent dashboard');

    openSettingsTab(refOf(tester));
    await settle(tester);
    openOverviewTab(refOf(tester));
    await settle(tester);

    expect(overviewTabsIn(container), [tabId]);
    expect(
      container.read(terminalSessionsControllerProvider).activeTabId,
      tabId,
    );
  });

  testWidgets('quick open has "Agent dashboard", found by its old name too', (
    tester,
  ) async {
    final container = await launch(tester);

    unawaited(QuickOpen.show(tester.element(find.byType(WorkbenchView))));
    await settle(tester);
    await tester.enterText(find.byType(TextField).last, 'overview');
    await settle(tester);
    await tester.tap(find.text('Open Agent dashboard'));
    await settle(tester);

    expect(overviewTabsIn(container), hasLength(1));
    expect(find.byType(OverviewTabView), findsOneWidget);
  });

  testWidgets('the activity strip opens it', (tester) async {
    final container = await launch(tester);
    openSettingsTab(refOf(tester));
    await settle(tester);

    // The strip's button: the dashboard's own page names itself too.
    await tester.tap(
      find.descendant(
        of: find.byType(ShellActivityStrip),
        matching: find.bySemanticsLabel('Agent dashboard'),
      ),
    );
    await settle(tester);

    expect(overviewTabsIn(container), hasLength(1));
    expect(
      container.read(terminalSessionsControllerProvider).activeTabId,
      overviewTabsIn(container).single,
    );
  });

  testWidgets('on the desktop it is pinned: there at start, with no close', (
    tester,
  ) async {
    final container = await launch(tester);

    final tabId = overviewTabsIn(container).single;
    expect(
      container.read(terminalSessionsControllerProvider).pinnedTabId,
      tabId,
    );
    final chip = find.byKey(ValueKey('pinned-tab:$tabId'));
    expect(chip, findsOneWidget);
    expect(
      find.descendant(of: chip, matching: find.byTooltip('Close tab')),
      findsNothing,
    );
    // Nothing else in the strip draws it again.
    expect(find.byType(TerminalTabChip), findsNothing);
  });

  testWidgets('Timeline is the second view, drawn from the activity log', (
    tester,
  ) async {
    await launch(tester);
    openOverviewTab(refOf(tester));
    await settle(tester);

    await tester.tap(find.text('Timeline'));
    await settle(tester);

    expect(find.byType(OverviewTimelineView), findsOneWidget);
    expect(find.text('The Timeline is not built yet.'), findsNothing);
  });

  testWidgets('a Timeline bar for a deleted session says so, and opens '
      'nothing', (tester) async {
    final container = await launch(tester);
    openOverviewTab(refOf(tester));
    await settle(tester);
    await tester.tap(find.text('Timeline'));
    await settle(tester);
    final tabsBefore = overviewTabsIn(container).length;

    final element = tester.element(find.byType(OverviewTimelineView));
    await openTimelineSession(element, element as WidgetRef, 'deleted-id');
    await tester.pump();

    expect(
      find.text('That session was deleted. Its history stays on the Timeline.'),
      findsOneWidget,
    );
    expect(overviewTabsIn(container), hasLength(tabsBefore));
  });

  test('its chord is Ctrl+Shift+O, and clashes with no other', () {
    final chord = defaultShellChords.where((c) => c.command == 'overview.open');
    expect(chord, hasLength(1));
    expect(chord.single.intent, isA<OpenOverviewIntent>());
    expect(chord.single.activator.trigger, LogicalKeyboardKey.keyO);
    expect(chord.single.activator.shift, isTrue);
    final same = defaultShellChords.where(
      (c) =>
          c.command != 'overview.open' &&
          c.activator.trigger == LogicalKeyboardKey.keyO &&
          c.activator.shift &&
          c.activator.control == chord.single.activator.control &&
          c.activator.meta == chord.single.activator.meta &&
          c.activator.alt == chord.single.activator.alt,
    );
    expect(same, isEmpty);
  });
}
