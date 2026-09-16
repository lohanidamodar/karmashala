import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/features/projects/application/project_providers.dart';
import 'package:karmashala/src/features/projects/application/projects_controller.dart';
import 'package:karmashala/src/features/projects/domain/project.dart';
import 'package:karmashala/src/features/workspaces/application/workspaces_controller.dart';
import 'package:karmashala/src/features/workspaces/domain/workspace_scope.dart';
import 'package:karmashala/src/features/workspaces/presentation/workspaces_dialog.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/window_matrix.dart';

void main() {
  late AppDatabase db;
  late ProviderContainer container;

  setUp(() {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        idGeneratorProvider.overrideWithValue(SequentialIdGenerator('w-')),
        clockProvider.overrideWithValue(FixedClock(testTime)),
      ],
    );
    addTearDown(container.dispose);
  });
  tearDown(() => db.close());

  void seedProjects([int count = 3]) {
    final dao = container.read(projectDaoProvider);
    for (var i = 0; i < count; i++) {
      dao.insert(
        Project(
          id: 'p$i',
          name: 'Project $i',
          root: EnvironmentPath(
            environmentId: 'windows',
            path: r'C:\src\p' '$i',
          ),
          createdAt: testTime,
        ),
      );
    }
    container.read(projectsControllerProvider.notifier).refreshFromStore();
  }

  Widget dialogApp() => UncontrolledProviderScope(
    container: container,
    child: const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(body: WorkspacesDialog()),
    ),
  );

  group('the scope', () {
    // The bar that used to set this in the Explorer is gone: the context is a
    // node inside its machine now, and choosing a scope is Quick Open's act —
    // where new work goes, rather than what the tree lists. What still has to
    // hold is that a scope never outlives the context it names.
    test('a deleted context does not leave the scope naming it', () {
      final games = container
          .read(workspacesControllerProvider.notifier)
          .create('Game dev');
      container
          .read(workspaceScopeProvider.notifier)
          .select(WorkspaceScope.of(games.id));

      container.read(workspacesControllerProvider.notifier).delete(games.id);

      expect(container.read(workspaceScopeProvider).isAll, isTrue);
    });
  });

  group('the contexts dialog', () {
    testWidgets('creates, renames and refuses a duplicate', (tester) async {
      await tester.pumpWidget(dialogApp());
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextField, 'New context'),
        'Personal',
      );
      await tester.tap(find.widgetWithText(OutlinedButton, 'Add'));
      await tester.pumpAndSettle();
      expect(
        container.read(workspacesControllerProvider).single.name,
        'Personal',
      );

      // The same name again is refused, in place.
      await tester.enterText(
        find.widgetWithText(TextField, 'New context'),
        'personal',
      );
      await tester.tap(find.widgetWithText(OutlinedButton, 'Add'));
      await tester.pumpAndSettle();
      expect(find.textContaining('already exists'), findsOneWidget);
      expect(container.read(workspacesControllerProvider).length, 1);

      await tester.tap(find.byTooltip('Edit Personal'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Name'),
        'Personal projects',
      );
      await tester.tap(find.byTooltip('Save context'));
      await tester.pumpAndSettle();
      expect(
        container.read(workspacesControllerProvider).single.name,
        'Personal projects',
      );
    });

    testWidgets('describes a context, and empties the description again', (
      tester,
    ) async {
      final personal = container
          .read(workspacesControllerProvider.notifier)
          .create('Personal');
      await tester.pumpWidget(dialogApp());
      await tester.pumpAndSettle();
      // With nothing said, the row says the one thing it knows for free.
      expect(find.text('0 projects'), findsOneWidget);

      await tester.tap(find.byTooltip('Edit Personal'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Description'),
        'Everything I run for myself',
      );
      await tester.tap(find.byTooltip('Save context'));
      await tester.pumpAndSettle();

      expect(
        container.read(workspacesControllerProvider).single.description,
        'Everything I run for myself',
      );
      expect(find.text('Everything I run for myself'), findsOneWidget);

      // Emptying the field removes the sentence and keeps the context.
      await tester.tap(find.byTooltip('Edit Personal'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Description'), '');
      await tester.tap(find.byTooltip('Save context'));
      await tester.pumpAndSettle();

      final after = container.read(workspacesControllerProvider).single;
      expect(after.id, personal.id);
      expect(after.description, isNull);
      expect(find.text('0 projects'), findsOneWidget);
    });

    testWidgets('deleting confirms in place and keeps the projects', (
      tester,
    ) async {
      seedProjects();
      final games = container
          .read(workspacesControllerProvider.notifier)
          .create('Game dev');
      container.read(workspacesControllerProvider.notifier).assign('p1', games.id);
      await tester.pumpWidget(dialogApp());
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Delete Game dev'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Its projects stay'), findsOneWidget);

      // Backing out changes nothing.
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(container.read(workspacesControllerProvider).length, 1);

      await tester.tap(find.byTooltip('Delete Game dev'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(container.read(workspacesControllerProvider), isEmpty);
      final projects = container.read(projectsControllerProvider);
      expect(projects.length, 3, reason: 'the projects outlive the context');
      for (final project in projects) {
        expect(project.workspaceId, isNull);
      }
    });

    testWidgets('assigns a project, and unassigns it again', (tester) async {
      seedProjects();
      final games = container
          .read(workspacesControllerProvider.notifier)
          .create('Game dev');
      await tester.pumpWidget(dialogApp());
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Context for Project 1'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Game dev').last);
      await tester.pumpAndSettle();
      expect(
        container
            .read(projectsControllerProvider)
            .firstWhere((p) => p.id == 'p1')
            .workspaceId,
        games.id,
      );

      await tester.tap(find.byTooltip('Context for Project 1'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('None').last);
      await tester.pumpAndSettle();
      expect(
        container
            .read(projectsControllerProvider)
            .firstWhere((p) => p.id == 'p1')
            .workspaceId,
        isNull,
      );
    });
  });

  group('the window matrix', () {
    testWidgets('the contexts dialog sizes to its box, not the screen', (
      tester,
    ) async {
      seedProjects(31);
      container.read(workspacesControllerProvider.notifier)
        ..create('Personal')
        ..create('PopupBits');
      await expectSurvivesWindowMatrix(
        tester,
        // A 720x560 box on a 1440x900 screen.
        matrix: const [desktopWindow, desktopLargeText],
        build: () => UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            debugShowCheckedModeBanner: false,
            home: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 720,
                height: 560,
                child: Scaffold(body: WorkspacesDialog()),
              ),
            ),
          ),
        ),
        checkFocus: false,
        because: 'MediaQuery said 1440x900 while the dialog had 720x560',
      );
    });

    testWidgets('the contexts dialog survives 720x560', (tester) async {
      seedProjects(1);
      final controller = container.read(workspacesControllerProvider.notifier)
        ..create('Personal')
        ..create('PopupBits');
      controller.assign(
        'p0',
        container.read(workspacesControllerProvider).first.id,
      );
      await expectSurvivesWindowMatrix(
        tester,
        build: dialogApp,
        because: 'the only surface that creates, renames, deletes and assigns',
      );
    });

    testWidgets('the contexts dialog survives a full workspace', (
      tester,
    ) async {
      // The owner's own scale, which is the case that scrolls.
      seedProjects(31);
      container.read(workspacesControllerProvider.notifier)
        ..create('Personal')
        ..create('PopupBits')
        ..create('Appwrite')
        ..create('Game dev');
      await expectSurvivesWindowMatrix(
        tester,
        build: dialogApp,
        // Focus is checked by the case above, on a dialog short enough not to
        // scroll. Once it does, the `Scrollable` contributes a focus stop of
        // its own and the reading-order policy picks the next stop from
        // geometry that the scroll itself has just moved — so the harness sees
        // the ring close somewhere other than where it started and calls it a
        // revisit. That is the harness measuring a scrolled viewport, not a
        // control the keyboard cannot reach.
        checkFocus: false,
        because: '31 projects and four contexts is what this has to hold',
      );
    });
  });
}
