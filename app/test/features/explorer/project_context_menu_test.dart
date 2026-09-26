import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/cli_detection/application/project_import_service.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_panel.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala/src/features/projects/application/projects_controller.dart';
import 'package:karmashala_projects/karmashala_projects.dart';
import 'package:karmashala/src/features/workspaces/application/workspaces_controller.dart';

import '../../support/fake_data_server.dart';
import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/window_matrix.dart';

/// **Filing a project, from the row it is already on.**
///
/// The owner's report was that context management "is not intuitive — I should
/// be able to add to context by right clicking a project, or remove from
/// context as well". The verbs live in the project row's own menu, which is
/// where every other thing you do to a project already lives.
///
/// Two properties this file exists to hold:
///
/// * **Moving is one gesture.** Every context, and *No context*, are rows in
///   the same list, so changing a project's context is one click on the answer
///   — never "remove from this one" followed by "add to that one".
/// * **Leaving a context is not leaving the workspace.** They are adjacent
///   items in one menu and they must never be confusable: one unassigns, the
///   other deletes.
void main() {
  late AppDatabase db;
  late ProviderContainer container;
  late FakeDataServer server;

  EnvironmentPath root(String path) =>
      EnvironmentPath(environmentId: localHostEnvironmentId, path: path);

  setUp(() async {
    db = AppDatabase.memory();
    server = FakeDataServer();
    server.environmentRows.upsert(
  localHostEnvironment(FixedClock(testTime).nowUtc()),
);
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        await server.override(),
        // Every session card asks git what its checkout has changed; a widget
        // test must never spawn one.
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(),
        ),
        idGeneratorProvider.overrideWithValue(SequentialIdGenerator('w-')),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        autoImportRunnerProvider.overrideWithValue(
          (_) async => const ImportSummary(),
        ),
      ],
    );
    addTearDown(container.dispose);
  });
  tearDown(() => db.close());

  Future<({String personal, String games})> seed({String? filedUnder}) async {
    final personal = (await createContext(container, 'Personal')).id;
    final games = (await createContext(
      container,
      'Game dev',
      description: 'Weekend things',
    )).id;
    server.projectRows.insert(
      Project(
        id: 'p1',
        name: 'Roguelike',
        root: root(r'C:\games\rl'),
        createdAt: testTime,
        workspaceId: filedUnder,
      ),
    );
    return (personal: personal, games: games);
  }

  Widget app() => UncontrolledProviderScope(
    container: container,
    child: const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(body: ExplorerPanel()),
    ),
  );

  /// A context is named twice now — on its chip above the list and in the
  /// menu — so the menu's own entry is asked for by where it is.
  Finder inMenu(String label) => find.descendant(
    of: find.byWidgetPredicate((widget) => widget is PopupMenuEntry),
    matching: find.text(label),
  );

  Future<void> openProjectMenu(WidgetTester tester) async {
    await tester.tap(find.byType(ProjectCard).first, buttons: kSecondaryButton);
    await tester.pumpAndSettle();
  }

  String? workspaceOfProject() => container
      .read(projectsControllerProvider)
      .firstWhere((p) => p.id == 'p1')
      .workspaceId;

  testWidgets('right-clicking a project files it under a context', (
    tester,
  ) async {
    final ids = await seed();
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    await openProjectMenu(tester);
    // The description is what tells two contexts apart at the moment of
    // choosing; a context nobody described says how big it is instead.
    expect(find.text('Weekend things'), findsOneWidget);
    expect(find.text('0 projects'), findsOneWidget);

    await tester.tap(inMenu('Game dev'));
    await tester.pumpAndSettle();

    expect(workspaceOfProject(), ids.games);
    expect(
      find.textContaining('Moved "Roguelike" to Game dev'),
      findsOneWidget,
    );
  });

  testWidgets('moving between contexts is one gesture, not two', (
    tester,
  ) async {
    final ids = await seed();
    await container
        .read(workspacesControllerProvider.notifier)
        .assign('p1', ids.personal);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    await openProjectMenu(tester);
    await tester.tap(inMenu('Game dev'));
    await tester.pumpAndSettle();

    expect(
      workspaceOfProject(),
      ids.games,
      reason: 'one click replaces the context; nothing had to be removed first',
    );
  });

  testWidgets('"No context" unassigns the project and keeps it', (
    tester,
  ) async {
    final ids = await seed(filedUnder: null);
    await container
        .read(workspacesControllerProvider.notifier)
        .assign('p1', ids.personal);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    await openProjectMenu(tester);
    await tester.tap(inMenu('No context'));
    await tester.pumpAndSettle();

    expect(workspaceOfProject(), isNull);
    expect(
      container.read(projectsControllerProvider).length,
      1,
      reason: 'leaving a context is not leaving the workspace',
    );
    expect(find.text('Roguelike'), findsOneWidget);
    expect(find.textContaining('It is still here'), findsOneWidget);
    // And both contexts are still there — unassigning one project deletes
    // nothing.
    expect(container.read(workspacesControllerProvider), hasLength(2));
  });

  testWidgets('an unassigned project is not offered "No context"', (
    tester,
  ) async {
    await seed();
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    await openProjectMenu(tester);
    expect(
      inMenu('No context'),
      findsNothing,
      reason: 'a verb that would do nothing is not a verb',
    );
    // The destructive one is still there, and is not the same words.
    expect(find.text('Remove from workspace'), findsOneWidget);
  });

  testWidgets('a new context can be made and filled in one go', (tester) async {
    server.projectRows.insert(
      Project(
        id: 'p1',
        name: 'Roguelike',
        root: root(r'C:\games\rl'),
        createdAt: testTime,
      ),
    );
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    await openProjectMenu(tester);
    // With no contexts at all, the only offer is to make one.
    await tester.tap(find.text('Add to a new context…'));
    await tester.pumpAndSettle();

    expect(find.textContaining('move "Roguelike" into it'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Game dev');
    await tester.enterText(
      find.widgetWithText(TextField, 'Description'),
      'Weekend things',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();

    final created = container.read(workspacesControllerProvider).single;
    expect(created.name, 'Game dev');
    expect(created.description, 'Weekend things');
    expect(workspaceOfProject(), created.id);
  });

  testWidgets('the menu with its contexts survives the window matrix', (
    tester,
  ) async {
    await seed();
    await expectSurvivesWindowMatrix(
      tester,
      // The container outlives the cells; only the tree is pumped afresh.
      build: app,
      warmUp: (tester) async {
        await tester.tap(
          find.byType(ProjectCard).first,
          buttons: kSecondaryButton,
        );
        await tester.pumpAndSettle();
      },
      // The menu is a route of its own over the pane; its rows are the surface
      // under test and Tab inside a `showMenu` route is the framework's ring,
      // not this pane's.
      checkFocus: false,
      because:
          'the row menu grew a context list and the Explorer is 200px wide',
    );
  });
}
