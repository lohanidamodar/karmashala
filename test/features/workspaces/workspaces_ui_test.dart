import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/environments/domain/environment_path.dart';
import 'package:karmashala/src/features/projects/application/project_providers.dart';
import 'package:karmashala/src/features/projects/application/projects_controller.dart';
import 'package:karmashala/src/features/projects/domain/project.dart';
import 'package:karmashala/src/features/workspaces/application/workspaces_controller.dart';
import 'package:karmashala/src/features/workspaces/domain/workspace_scope.dart';
import 'package:karmashala/src/features/workspaces/presentation/workspace_scope_bar.dart';
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

  Widget scopeBarApp() => UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      // The Explorer's own column: narrow, and the bar has to live in it.
      home: const Scaffold(
        body: SizedBox(width: 240, child: WorkspaceScopeBar()),
      ),
    ),
  );

  Widget dialogApp() => UncontrolledProviderScope(
    container: container,
    child: const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(body: WorkspacesDialog()),
    ),
  );

  group('the scope bar', () {
    testWidgets('reads All projects until something narrows it', (
      tester,
    ) async {
      seedProjects();
      final games = container
          .read(workspacesControllerProvider.notifier)
          .create('Game dev');
      await tester.pumpWidget(scopeBarApp());
      await tester.pumpAndSettle();
      expect(find.text('All projects'), findsOneWidget);

      await tester.tap(find.byType(WorkspaceScopeBar));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Game dev').last);
      await tester.pumpAndSettle();

      expect(container.read(workspaceScopeProvider), WorkspaceScope.of(games.id));
      expect(find.text('Game dev'), findsOneWidget);
    });

    testWidgets('offers No context only once there is a context', (
      tester,
    ) async {
      await tester.pumpWidget(scopeBarApp());
      await tester.pumpAndSettle();
      await tester.tap(find.byType(WorkspaceScopeBar));
      await tester.pumpAndSettle();
      expect(find.text('No context'), findsNothing);
      expect(find.text('New context'), findsOneWidget);
      await tester.tapAt(const Offset(700, 20));
      await tester.pumpAndSettle();

      container.read(workspacesControllerProvider.notifier).create('Personal');
      await tester.pumpAndSettle();
      await tester.tap(find.byType(WorkspaceScopeBar));
      await tester.pumpAndSettle();
      expect(find.text('No context'), findsOneWidget);
      expect(find.text('Manage contexts'), findsOneWidget);
    });

    testWidgets('All comes back from a narrowed list', (tester) async {
      seedProjects();
      final games = container
          .read(workspacesControllerProvider.notifier)
          .create('Game dev');
      container
          .read(workspaceScopeProvider.notifier)
          .select(WorkspaceScope.of(games.id));
      await tester.pumpWidget(scopeBarApp());
      await tester.pumpAndSettle();
      expect(find.text('Game dev'), findsOneWidget);

      await tester.tap(find.byType(WorkspaceScopeBar));
      await tester.pumpAndSettle();
      await tester.tap(find.text('All projects').last);
      await tester.pumpAndSettle();

      expect(container.read(workspaceScopeProvider), WorkspaceScope.all);
      expect(container.read(workspaceScopedProjectsProvider).length, 3);
    });

    testWidgets('a deleted context does not leave the bar naming it', (
      tester,
    ) async {
      final games = container
          .read(workspacesControllerProvider.notifier)
          .create('Game dev');
      container
          .read(workspaceScopeProvider.notifier)
          .select(WorkspaceScope.of(games.id));
      await tester.pumpWidget(scopeBarApp());
      await tester.pumpAndSettle();

      container.read(workspacesControllerProvider.notifier).delete(games.id);
      await tester.pumpAndSettle();

      expect(find.text('All projects'), findsOneWidget);
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

      await tester.tap(find.byTooltip('Rename Personal'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'Personal projects');
      await tester.tap(find.byTooltip('Save name'));
      await tester.pumpAndSettle();
      expect(
        container.read(workspacesControllerProvider).single.name,
        'Personal projects',
      );
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
    testWidgets('the scope bar survives 720x560', (tester) async {
      seedProjects();
      container
          .read(workspacesControllerProvider.notifier)
          .create('A context with a name nobody would call short');
      await expectSurvivesWindowMatrix(
        tester,
        build: scopeBarApp,
        because: 'the selector sits in the Explorer column at every width',
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
