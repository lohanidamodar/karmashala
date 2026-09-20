import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/projects/application/project_providers.dart';
import 'package:karmashala/src/features/projects/application/projects_controller.dart';
import 'package:karmashala/src/features/workspaces/application/workspaces_controller.dart';
import 'package:karmashala/src/features/workspaces/domain/workspace_scope.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';

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
  });
  tearDown(() {
    container.dispose();
    db.close();
  });

  WorkspacesController controller() =>
      container.read(workspacesControllerProvider.notifier);

  void seedProjects() {
    final dao = container.read(projectDaoProvider);
    dao.insert(project(id: 'p1', name: 'Karmashala'));
    dao.insert(project(id: 'p2', name: 'Roguelike'));
    dao.insert(project(id: 'p3', name: 'Journal'));
    container.read(projectsControllerProvider.notifier).refreshFromStore();
  }

  group('the four verbs', () {
    test('starts empty and creates', () {
      expect(container.read(workspacesControllerProvider), isEmpty);
      final created = controller().create('  PopupBits  ');
      expect(created.name, 'PopupBits', reason: 'the name is trimmed');
      expect(container.read(workspacesControllerProvider).single, created);
    });

    test('refuses an empty name and a duplicate one', () {
      controller().create('Personal');
      expect(() => controller().create('   '), throwsArgumentError);
      expect(
        () => controller().create('personal'),
        throwsA(isA<DuplicateWorkspaceName>()),
      );
      expect(container.read(workspacesControllerProvider).length, 1);
    });

    test('renames, and lets a workspace keep its own name', () {
      final one = controller().create('Personal');
      controller().rename(one.id, 'Personal projects');
      expect(
        container.read(workspacesControllerProvider).single.name,
        'Personal projects',
      );
      // Renaming to what it already is must not trip the duplicate check.
      controller().rename(one.id, 'Personal projects');
      controller().create('Appwrite');
      expect(
        () => controller().rename(one.id, 'appwrite'),
        throwsA(isA<DuplicateWorkspaceName>()),
      );
    });

    test('assign files a project and unassigns it again', () {
      seedProjects();
      final games = controller().create('Game dev');
      controller().assign('p2', games.id);

      final filed = container
          .read(projectsControllerProvider)
          .firstWhere((p) => p.id == 'p2');
      expect(filed.workspaceId, games.id);

      controller().assign('p2', null);
      expect(
        container
            .read(projectsControllerProvider)
            .firstWhere((p) => p.id == 'p2')
            .workspaceId,
        isNull,
      );
    });
  });

  group('deleting a context', () {
    test('leaves its projects, unassigned', () {
      seedProjects();
      final games = controller().create('Game dev');
      controller().assign('p2', games.id);

      controller().delete(games.id);

      expect(container.read(workspacesControllerProvider), isEmpty);
      final projects = container.read(projectsControllerProvider);
      expect(projects.map((p) => p.id), ['p1', 'p2', 'p3']);
      for (final p in projects) {
        expect(p.workspaceId, isNull);
      }
    });

    test('falls back to All when the deleted one was being shown', () {
      seedProjects();
      final games = controller().create('Game dev');
      container
          .read(workspaceScopeProvider.notifier)
          .select(WorkspaceScope.of(games.id));

      controller().delete(games.id);

      expect(container.read(workspaceScopeProvider), WorkspaceScope.all);
      expect(container.read(workspaceScopedProjectsProvider).length, 3);
    });

    test('leaves an unrelated selection alone', () {
      final personal = controller().create('Personal');
      final games = controller().create('Game dev');
      container
          .read(workspaceScopeProvider.notifier)
          .select(WorkspaceScope.of(personal.id));

      controller().delete(games.id);

      expect(
        container.read(workspaceScopeProvider),
        WorkspaceScope.of(personal.id),
      );
    });
  });

  group('the filter', () {
    test('narrows the list, and All restores it', () {
      seedProjects();
      final games = controller().create('Game dev');
      controller().assign('p2', games.id);

      expect(container.read(workspaceScopedProjectsProvider).length, 3);

      container
          .read(workspaceScopeProvider.notifier)
          .select(WorkspaceScope.of(games.id));
      expect(container.read(workspaceScopedProjectsProvider).map((p) => p.id), [
        'p2',
      ]);

      container
          .read(workspaceScopeProvider.notifier)
          .select(WorkspaceScope.all);
      expect(container.read(workspaceScopedProjectsProvider).map((p) => p.id), [
        'p1',
        'p2',
        'p3',
      ]);
    });

    test(
      'an unassigned project is reachable under All and under Unassigned',
      () {
        seedProjects();
        final games = controller().create('Game dev');
        controller().assign('p2', games.id);

        expect(
          container.read(workspaceScopedProjectsProvider).map((p) => p.id),
          contains('p3'),
          reason: 'never hidden by default',
        );

        container
            .read(workspaceScopeProvider.notifier)
            .select(WorkspaceScope.unassigned);
        expect(
          container.read(workspaceScopedProjectsProvider).map((p) => p.id),
          ['p1', 'p3'],
        );
      },
    );

    test('a context with nothing in it shows nothing, not everything', () {
      seedProjects();
      final empty = controller().create('Appwrite');
      container
          .read(workspaceScopeProvider.notifier)
          .select(WorkspaceScope.of(empty.id));
      expect(container.read(workspaceScopedProjectsProvider), isEmpty);
    });

    test('assigning a project moves it between scopes at once', () {
      seedProjects();
      final games = controller().create('Game dev');
      container
          .read(workspaceScopeProvider.notifier)
          .select(WorkspaceScope.of(games.id));
      expect(container.read(workspaceScopedProjectsProvider), isEmpty);

      controller().assign('p2', games.id);
      expect(container.read(workspaceScopedProjectsProvider).map((p) => p.id), [
        'p2',
      ]);
    });
  });

  group('the selected project', () {
    test('survives a filter that excludes it, and stays visible', () {
      // Decided: filtering is a view, not a navigation action. The selection
      // drives the session list, the chat and the terminal, so it is neither
      // cleared (which throws away what you were doing) nor hidden (which
      // leaves the session pane showing work whose project is nowhere on
      // screen). It stays, and its row stays with it.
      seedProjects();
      final games = controller().create('Game dev');
      controller().assign('p2', games.id);
      container.read(selectedProjectIdProvider.notifier).select('p1');

      container
          .read(workspaceScopeProvider.notifier)
          .select(WorkspaceScope.of(games.id));

      expect(container.read(selectedProjectIdProvider), 'p1');
      expect(container.read(workspaceScopedProjectsProvider).map((p) => p.id), [
        'p1',
        'p2',
      ], reason: 'the project being worked in is never filtered away');
    });

    test('is not smuggled in twice when it is in scope anyway', () {
      seedProjects();
      final games = controller().create('Game dev');
      controller().assign('p2', games.id);
      container.read(selectedProjectIdProvider.notifier).select('p2');

      container
          .read(workspaceScopeProvider.notifier)
          .select(WorkspaceScope.of(games.id));

      expect(container.read(workspaceScopedProjectsProvider).map((p) => p.id), [
        'p2',
      ]);
    });

    test('no selection means no exception to the filter', () {
      seedProjects();
      final games = controller().create('Game dev');
      controller().assign('p2', games.id);

      container
          .read(workspaceScopeProvider.notifier)
          .select(WorkspaceScope.of(games.id));

      expect(container.read(workspaceScopedProjectsProvider).map((p) => p.id), [
        'p2',
      ]);
    });
  });
}
