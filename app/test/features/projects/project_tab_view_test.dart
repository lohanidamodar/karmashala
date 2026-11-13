import 'package:agent_cli/process.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/explorer/application/checkout_picker.dart';
import 'package:karmashala/src/features/projects/application/project_page.dart';
import 'package:karmashala/src/features/projects/application/project_tabs.dart';
import 'package:karmashala/src/features/projects/application/projects_controller.dart';
import 'package:karmashala/src/features/projects/presentation/project_tab_view.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_session/delivery.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_terminal_core/geometry.dart';
import 'package:karmashala_ui/theme.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';
import '../terminal/fake_instance.dart';

/// **A project's page** (owner, 2026-11-13): its details and settings, its
/// checkouts with their worktrees, its sessions and its files — a tab per
/// project, which closes with the project.
void main() {
  late TestMachine db;
  late FakeDataServer server;

  const worktreePath = EnvironmentPath(
    environmentId: 'windows',
    path: r'C:\src\demo-wt\fix',
  );

  setUp(() {
    db = TestMachine();
    server = FakeDataServer()..runsOn(db);
    server.environmentRows.upsert(windowsEnv());
    server.installationRows.insert(agentInstallation());
    server.projectRows.insert(project(id: 'p1', name: 'Alpha'));
    server.repositoryRows.insert(repository(id: 'r1', projectId: 'p1'));
    server.repositoryRows.insert(
      repository(
        id: 'r2',
        projectId: 'p1',
        name: 'fix',
        path: worktreePath.path,
      ),
    );
    db.server.sessionRows.insert(
      Session(
        id: 's1',
        repositoryId: 'r1',
        agentInstallationId: 'a1',
        title: 'Live one',
        useWorktree: false,
        status: SessionStatus.completed,
        createdAt: testTime,
      ),
    );
    db.server.sessionRows.insert(
      Session(
        id: 's2',
        repositoryId: 'r1',
        agentInstallationId: 'a1',
        title: 'Old one',
        useWorktree: false,
        status: SessionStatus.completed,
        createdAt: testTime,
        archivedAt: testTime,
      ),
    );
  });

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    Size size = const Size(1440, 900),
    double textScale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(machine: db, data: await server.override()),
        idGeneratorProvider.overrideWithValue(SequentialIdGenerator('w-')),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(),
        ),
        checkoutLabelsProvider.overrideWith(
          (ref, projectId) async => const {
            'r1': CheckoutLabel(isWorktree: false, branch: 'main'),
            'r2': CheckoutLabel(
              isWorktree: true,
              branch: 'fix/thing',
              ownerRepositoryId: 'r1',
            ),
          },
        ),
        checkoutDeliveryProvider.overrideWith(
          (ref, checkout) async =>
              const SessionDelivery(dirtyFiles: 2, aheadOfBase: 3),
        ),
        projectPathMissingProvider.overrideWith((ref, project) async => false),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.dark(),
          home: MediaQuery.withClampedTextScaling(
            minScaleFactor: textScale,
            maxScaleFactor: textScale,
            child: const Scaffold(body: ProjectTabView(projectId: 'p1')),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  Finder byKey(String key) => find.byKey(ValueKey(key));

  Future<void> section(WidgetTester tester, ProjectSection value) async {
    await tester.tap(byKey('project-section:${value.name}'));
    await tester.pumpAndSettle();
  }

  testWidgets('Details says where it is, and counts its sessions and '
      'checkouts', (tester) async {
    await pump(tester);
    expect(find.text('Alpha'), findsWidgets);
    expect(find.text(r'C:\src\demo'), findsOneWidget);
    expect(
      tester.widget<Text>(byKey('project-fact-sessions')).data,
      '2 · 1 archived',
    );
    expect(
      tester.widget<Text>(byKey('project-fact-checkouts')).data,
      '1 · 1 worktree',
    );
    // Its settings are on the page, not behind a dialog.
    expect(byKey('project-setting-name'), findsOneWidget);
    expect(byKey('project-setting-context'), findsOneWidget);
    expect(byKey('project-setting-default-checkout'), findsOneWidget);
  });

  testWidgets('renaming on the page saves the project', (tester) async {
    final c = await pump(tester);
    await tester.enterText(byKey('project-setting-name'), 'Beta');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(c.read(projectByIdProvider('p1'))?.name, 'Beta');
  });

  testWidgets('Checkouts nests the worktree under its checkout, with what '
      'git says of each', (tester) async {
    await pump(tester);
    await section(tester, ProjectSection.checkouts);
    expect(byKey('project-checkout:r1'), findsOneWidget);
    expect(byKey('project-checkout:r2'), findsOneWidget);
    expect(
      tester.widget<Text>(byKey('project-checkout-facts:r2')).data,
      'fix/thing · 2 changed · 3 ahead',
    );
    // Only a worktree offers to be removed.
    await tester.tap(byKey('project-checkout-menu:r1'));
    await tester.pumpAndSettle();
    expect(find.text('Remove worktree…'), findsNothing);
    await tester.tapAt(Offset.zero);
    await tester.pumpAndSettle();
    await tester.tap(byKey('project-checkout-menu:r2'));
    await tester.pumpAndSettle();
    expect(find.text('Remove worktree…'), findsOneWidget);
  });

  testWidgets('removing a dirty worktree warns that its changes are lost', (
    tester,
  ) async {
    await pump(tester);
    await section(tester, ProjectSection.checkouts);
    await tester.tap(byKey('project-checkout-menu:r2'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove worktree…'));
    await tester.pumpAndSettle();
    expect(find.text('Remove worktree "fix"?'), findsOneWidget);
    expect(find.textContaining('2 uncommitted changes'), findsOneWidget);
    expect(find.text('Discard and remove'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Remove worktree "fix"?'), findsNothing);
  });

  testWidgets('Sessions lists the active ones, and Archived the archived', (
    tester,
  ) async {
    await pump(tester);
    await section(tester, ProjectSection.sessions);
    expect(find.text('Live one'), findsOneWidget);
    expect(find.text('Old one'), findsNothing);
    await tester.tap(byKey('project-session-filter:archived'));
    await tester.pumpAndSettle();
    expect(find.text('Old one'), findsOneWidget);
    expect(find.text('Live one'), findsNothing);
  });

  for (final value in ProjectSection.values) {
    testWidgets('${value.label} fits a 360 px phone at text scale 1.6', (
      tester,
    ) async {
      await pump(tester, size: const Size(360, 780), textScale: 1.6);
      await section(tester, value);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('its tab is named for the project, and closes with it', (
    tester,
  ) async {
    final c = await pump(tester);
    c.listen(projectTabsObserverProvider, (_, _) {});
    final terminals = c.read(terminalSessionsControllerProvider.notifier);
    final tabId = terminals.openDocumentTab(projectPaneId('p1'));
    await tester.pumpAndSettle();
    expect(terminals.titleForTab(tabId), 'Alpha');

    await c.read(projectsControllerProvider.notifier).deleteProject('p1');
    await tester.pumpAndSettle();
    expect(
      c
          .read(terminalTabsProvider)
          .any((tab) => tab.layout.panes.contains(projectPaneId('p1'))),
      isFalse,
    );
  });

  test('a worktree whose checkout is not recorded is listed on its own', () {
    final rows = [
      repository(id: 'r1'),
      repository(id: 'r2', name: 'fix', path: worktreePath.path),
      repository(id: 'r3', name: 'stray', path: r'C:\elsewhere\stray'),
    ];
    final tree = projectCheckoutTree(rows, const {
      'r2': CheckoutLabel(isWorktree: true, ownerRepositoryId: 'r1'),
      'r3': CheckoutLabel(isWorktree: true, ownerRepositoryId: 'gone'),
    });
    expect([for (final c in tree) c.repository.id], ['r1', 'r3']);
    expect([for (final w in tree.first.worktrees) w.repository.id], ['r2']);
    expect(tree.last.isWorktree, isTrue);
    expect(tree.last.parent, isNull);
  });
}
