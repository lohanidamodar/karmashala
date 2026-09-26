import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/projects/application/projects_controller.dart';
import 'package:karmashala/src/features/workspaces/application/workspaces_controller.dart';
import 'package:karmashala/src/features/workspaces/domain/workspace_scope.dart';

import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

void main() {
  late AppDatabase db;
  late ProviderContainer container;
  late FakeDataServer server;

  setUp(() async {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    server = FakeDataServer(clock: () => testTime);
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        await server.override(),
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
    server.projectRows
      ..insert(project(id: 'p1', name: 'Karmashala'))
      ..insert(project(id: 'p2', name: 'Roguelike'))
      ..insert(project(id: 'p3', name: 'Journal'));
  }

  group('deleting a context', () {
    test('falls back to All when the deleted one was being shown', () async {
      seedProjects();
      final games = await controller().create('Game dev');
      container
          .read(workspaceScopeProvider.notifier)
          .select(WorkspaceScope.of(games.id));

      await controller().delete(games.id);

      expect(container.read(workspaceScopeProvider), WorkspaceScope.all);
      expect(container.read(workspaceScopedProjectsProvider).length, 3);
    });

    test('leaves an unrelated selection alone', () async {
      final personal = await controller().create('Personal');
      final games = await controller().create('Game dev');
      container
          .read(workspaceScopeProvider.notifier)
          .select(WorkspaceScope.of(personal.id));

      await controller().delete(games.id);

      expect(
        container.read(workspaceScopeProvider),
        WorkspaceScope.of(personal.id),
      );
    });
  });

  group('the filter', () {
    test('narrows the list, and All restores it', () async {
      seedProjects();
      final games = await controller().create('Game dev');
      await controller().assign('p2', games.id);

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
      () async {
        seedProjects();
        final games = await controller().create('Game dev');
        await controller().assign('p2', games.id);

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

    test(
      'a context with nothing in it shows nothing, not everything',
      () async {
        seedProjects();
        final empty = await controller().create('Appwrite');
        container
            .read(workspaceScopeProvider.notifier)
            .select(WorkspaceScope.of(empty.id));
        expect(container.read(workspaceScopedProjectsProvider), isEmpty);
      },
    );

    test('assigning a project moves it between scopes at once', () async {
      seedProjects();
      final games = await controller().create('Game dev');
      container
          .read(workspaceScopeProvider.notifier)
          .select(WorkspaceScope.of(games.id));
      expect(container.read(workspaceScopedProjectsProvider), isEmpty);

      await controller().assign('p2', games.id);
      expect(container.read(workspaceScopedProjectsProvider).map((p) => p.id), [
        'p2',
      ]);
    });
  });

  group('the selected project', () {
    test('survives a filter that excludes it, and stays visible', () async {
      // Decided: filtering is a view, not a navigation action. The selection
      // drives the session list, the chat and the terminal, so it is neither
      // cleared (which throws away what you were doing) nor hidden (which
      // leaves the session pane showing work whose project is nowhere on
      // screen). It stays, and its row stays with it.
      seedProjects();
      final games = await controller().create('Game dev');
      await controller().assign('p2', games.id);
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

    test('is not smuggled in twice when it is in scope anyway', () async {
      seedProjects();
      final games = await controller().create('Game dev');
      await controller().assign('p2', games.id);
      container.read(selectedProjectIdProvider.notifier).select('p2');

      container
          .read(workspaceScopeProvider.notifier)
          .select(WorkspaceScope.of(games.id));

      expect(container.read(workspaceScopedProjectsProvider).map((p) => p.id), [
        'p2',
      ]);
    });

    test('no selection means no exception to the filter', () async {
      seedProjects();
      final games = await controller().create('Game dev');
      await controller().assign('p2', games.id);

      container
          .read(workspaceScopeProvider.notifier)
          .select(WorkspaceScope.of(games.id));

      expect(container.read(workspaceScopedProjectsProvider).map((p) => p.id), [
        'p2',
      ]);
    });
  });
}
