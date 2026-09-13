import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/karmashala_app.dart';
import 'package:karmashala/src/app/shell/side_panel_state.dart';
import 'package:karmashala/src/app/shell/workbench.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/git/application/changes_providers.dart';
import 'package:karmashala/src/features/git/application/diff_tab_actions.dart';
import 'package:karmashala/src/features/git/presentation/changes_view.dart';
import 'package:karmashala/src/features/git/presentation/diff_tab_view.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_git/git.dart';
import 'package:karmashala_terminal_core/geometry.dart';

import '../../features/scale/scale_harness.dart';
import '../../features/terminal/fake_instance.dart';
import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// **Reading a change happens in a tab; the sidebar only says what changed.**
///
/// The Changes panel used to expand each file to its diff inside a 300px
/// column, with a dialog for anyone who wanted room. What this pins is the
/// replacement: a row opens a workbench tab, one tab per file, and the tab
/// keeps showing the file it was opened on.
const _file = 'lib/src/app/shell/side_panel.dart';
const _diff =
    '@@ -1,3 +1,3 @@\n final a = 1;\n-final b = 2;\n+final b = 3;\n final c = 4;\n';

void main() {
  late CountingDatabase db;

  setUp(() {
    db = CountingDatabase();
    ensureLocalEnvironment(ExecutionEnvironmentDao(db), FixedClock(testTime));
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    AgentInstallationDao(db).insert(agentInstallation());
  });
  tearDown(() => db.close());

  ProviderContainer shellContainer() {
    final container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(fallback: FakeCommandRunner()),
        ),
        hostCommandRunnerProvider.overrideWithValue(FakeCommandRunner()),
        repositoryChangesProvider.overrideWith(
          (ref) async => const [
            FileChange(
              path: _file,
              type: FileChangeType.modified,
              staged: false,
              unstaged: true,
            ),
          ],
        ),
        repositoryFileDiffStatsProvider.overrideWith(
          (ref) async => const {_file: FileDiffStat(added: 1, removed: 1)},
        ),
        repoWorktreesProvider.overrideWith((ref) async => const []),
        recentCommitsProvider.overrideWith((ref) async => const []),
        fileDiffByPathProvider(_file).overrideWith((ref) async => _diff),
        // What a tab reads: its own checkout's diff, not the sidebar's.
        diffForTargetProvider.overrideWith((ref, target) async => _diff),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));
  }

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
    // A checkout has to be selected before anything has changes to list.
    container
        .read(selectedRepositoryIdProvider.notifier)
        .select(repository().id);
    // `select` on the surface already showing *collapses* it — that is the
    // rail's gesture — so drive it from closed rather than through the toggle.
    container.read(sidePanelProvider.notifier).collapse();
    container.read(sidePanelProvider.notifier).select(SidePanelSurface.changes);
    await settle(tester);
    return container;
  }

  WidgetRef refOf(WidgetTester tester) =>
      tester.element(find.byType(WorkbenchView)) as WidgetRef;

  /// The sidebar's own row. Once its tab is open the chip says the same name.
  final sidebarRow = find.descendant(
    of: find.byType(ChangesView),
    matching: find.text('side_panel.dart'),
  );

  List<String> diffTabsIn(ProviderContainer container) => [
    for (final tab in container.read(terminalSessionsControllerProvider).tabs)
      if (tab.layout.panes.any(isDiffPane)) tab.id,
  ];

  testWidgets('the sidebar lists the file and shows no diff of its own', (
    tester,
  ) async {
    await launch(tester);

    expect(find.text('side_panel.dart'), findsOneWidget);
    expect(find.text('lib/src/app/shell'), findsOneWidget);
    expect(find.text('+1 −1'), findsOneWidget);
    expect(find.byType(DiffTabView), findsNothing);
    expect(find.text('+final b = 3;'), findsNothing);
  });

  testWidgets('clicking a row opens its diff in a tab, once', (tester) async {
    final container = await launch(tester);

    await tester.tap(sidebarRow);
    await settle(tester);

    expect(find.byType(DiffTabView), findsOneWidget);
    expect(find.text('+final b = 3;'), findsOneWidget);
    expect(diffTabsIn(container), hasLength(1));
    final tabId = diffTabsIn(container).single;
    expect(
      container.read(terminalSessionsControllerProvider).activeTabId,
      tabId,
    );

    // A second click is the same tab, not a second copy of the same diff.
    await tester.tap(sidebarRow);
    await settle(tester);
    expect(diffTabsIn(container), [tabId]);
  });

  testWidgets('the tab is named after the file, not the path', (tester) async {
    await launch(tester);
    refOf(tester).read(diffTabActionsProvider).open(_file);
    await settle(tester);

    // The sidebar row and the tab chip say the name; the pane header wears it
    // uppercased, like every other chrome eyebrow in the app.
    expect(find.text('side_panel.dart'), findsNWidgets(2));
    expect(find.text('SIDE_PANEL.DART'), findsOneWidget);
  });

  testWidgets('the tab keeps the checkout it was opened on', (tester) async {
    final container = await launch(tester);
    final opened = container.read(viewedCheckoutProvider);

    refOf(tester).read(diffTabActionsProvider).open(_file);
    await settle(tester);

    final paneId = container
        .read(terminalSessionsControllerProvider)
        .tabs
        .expand((tab) => tab.layout.panes)
        .firstWhere(isDiffPane);
    final target = diffTargetOf(paneId);
    expect(target, isNotNull);
    expect(target!.checkout, opened);
    expect(target.path, _file);
    // And it survives being written down, which is what restore reads back.
    expect(diffPaneIdFor(target), paneId);
  });
}
