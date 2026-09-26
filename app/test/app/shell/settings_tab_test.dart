import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/karmashala_app.dart';
import 'package:karmashala/src/app/shell/workbench.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/environments/presentation/environments_section.dart';
import 'package:karmashala/src/features/settings/presentation/settings_nav.dart';
import 'package:karmashala/src/features/settings/presentation/settings_screen.dart';
import 'package:karmashala/src/features/settings/presentation/settings_tab_view.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_runtime/system_terminals.dart';
import 'package:karmashala/src/features/terminal/application/terminal_theme_controller.dart';
import 'package:karmashala_terminal_core/geometry.dart';
import 'package:karmashala_terminal_core/profiles.dart';

import '../../features/scale/scale_harness.dart';
import '../../features/terminal/fake_instance.dart';
import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/fake_data_server.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

/// **Settings is a workbench tab, not a route over the window.**
///
/// The report: settings that govern panes you would want to watch while
/// changing them — terminal integration, the session host switch, the Flutter
/// SDK paths, the automations — were behind a full-screen `MaterialPageRoute`
/// that covered the menu bar, the tab strip and the pane the setting was
/// about. VS Code's answer is an editor tab, and so is ours.
///
/// What this pins down is the whole of that claim: one tab however many times
/// it is asked for, a deep link that lands on its page, a tab that comes back
/// after a restart like any other, the menu bar still on screen while it is
/// open — and, because a tab nobody is looking at must not be a second
/// subscriber to everything the app knows, **zero statements while it is not
/// the tab on screen**.
void main() {
  late CountingDatabase db;
  late FakeDataServer server;
  late Override data;

  setUp(() async {
    db = CountingDatabase();
    server = FakeDataServer();
    data = await server.override();
    ensureLocalEnvironment(ExecutionEnvironmentDao(db), FixedClock(testTime));
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    AgentInstallationDao(db).insert(agentInstallation());
  });
  tearDown(() => db.close());

  ProviderContainer shellContainer() {
    final container = ProviderContainer(
      overrides: [
        data,
        ...fakeTerminalOverrides(database: db),
        // Nothing here may shell out or read a real Ghostty/Warp directory:
        // the settings pages this opens probe both.
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(fallback: FakeCommandRunner()),
        ),
        hostCommandRunnerProvider.overrideWithValue(FakeCommandRunner()),
        discoveredTerminalThemesProvider.overrideWithValue(const []),
        availableSystemTerminalsProvider.overrideWith(
          (ref) async => const <SystemTerminal>[],
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  /// The whole shell, at a width where the settings page is master-detail.
  Future<ProviderContainer> launch(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final container = shellContainer();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const KarmashalaApp(),
      ),
    );
    // Bounded pumps, never `pumpAndSettle`: a terminal pane blinks its cursor
    // for ever, so nothing in this tree ever settles.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 200));
    return container;
  }

  /// A `WidgetRef` out of the mounted tree, so the test drives the same verb
  /// the menu, the chord, quick open and the usage chip all call.
  WidgetRef refOf(WidgetTester tester) =>
      tester.element(find.byType(WorkbenchView)) as WidgetRef;

  List<String> settingsTabsIn(ProviderContainer container) => [
    for (final tab in container.read(terminalSessionsControllerProvider).tabs)
      if (tab.layout.panes.any(isSettingsPane)) tab.id,
  ];

  testWidgets('opens one tab, and opening it again focuses that one', (
    tester,
  ) async {
    final container = await launch(tester);

    openSettingsTab(refOf(tester));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(settingsTabsIn(container), hasLength(1));
    final tabId = settingsTabsIn(container).single;
    expect(
      container.read(terminalSessionsControllerProvider).activeTabId,
      tabId,
    );

    // The second ask is the whole point: a route pushed a second copy over the
    // first, which is how you ended up three deep in a page you could not see
    // the app behind.
    openSettingsTab(refOf(tester));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(settingsTabsIn(container), [tabId]);
    expect(find.byType(SettingsScreen), findsOneWidget);
  });

  testWidgets('the menu bar is still there while Settings is open', (
    tester,
  ) async {
    await launch(tester);

    openSettingsTab(refOf(tester));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    // The reported bug, stated as a finder: the route covered the window, so
    // the one row carrying File, Workspace and View went with it.
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(find.byType(MenuBar), findsOneWidget);
  });

  testWidgets('a deep link opens the tab on the page it names', (tester) async {
    await launch(tester);

    openSettingsTab(refOf(tester), section: SettingsSectionId.environments);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.byType(EnvironmentsSection), findsOneWidget);
  });

  testWidgets('it comes back after a restart, like any tab', (tester) async {
    // Written by one container and read by another, which is what a quit and a
    // relaunch are. The pane behind it has no process, so this is exactly the
    // case a stored layout used to drop.
    final first = fakeTerminalContainer(database: db);
    final terminals = first.read(terminalSessionsControllerProvider.notifier);
    terminals.openTab(TerminalProfile.powerShell);
    terminals.openSettingsTab();
    terminals.persistLayout();
    first.dispose();

    final container = await launch(tester);

    expect(settingsTabsIn(container), hasLength(1));
    expect(find.byType(SettingsScreen), findsOneWidget);
  });

  testWidgets('a Settings tab nobody is looking at reads nothing', (
    tester,
  ) async {
    final container = await launch(tester);
    final shellTab = container
        .read(terminalSessionsControllerProvider)
        .tabs
        .first
        .id;

    // Environments rather than the landing page: it is the section that reads
    // the most — the environments, the agent installations and the SSH hosts —
    // so a subscription left behind would show up as statements.
    openSettingsTab(refOf(tester), section: SettingsSectionId.environments);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(EnvironmentsSection), findsOneWidget);
    expect(
      db.reads,
      isNotEmpty,
      reason: 'the shown page has to cost something',
    );

    activateTerminalTab(refOf(tester), shellTab);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    // **`skipOffstage: false` is the whole assertion.** The default finder
    // cannot see a hidden `IndexedStack` child at all — `debugVisitOnstageChildren`
    // skips it — so a plain `findsNothing` here would pass just as well for a
    // page that was built and merely not painted, which is the cost being
    // removed rather than the proof it is gone. This says the element is not
    // in the tree, and an element that does not exist holds no subscription.
    expect(find.byType(SettingsScreen, skipOffstage: false), findsNothing);
    // Counted, never timed: builds of the surface, and statements through the
    // database, over a stretch of the app's life with the tab open behind
    // another one. Both stay where they were.
    db.reset();
    final builds = SettingsTabView.debugBuildCount;
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));
    expect(SettingsTabView.debugBuildCount, builds);
    expect(db.count, 0, reason: '${db.statements}');

    // And it is still a tab: coming back rebuilds it on the page it was left
    // on, which is what makes the gate above affordable rather than a loss.
    activateTerminalTab(refOf(tester), settingsTabsIn(container).single);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(EnvironmentsSection), findsOneWidget);
  });
}
