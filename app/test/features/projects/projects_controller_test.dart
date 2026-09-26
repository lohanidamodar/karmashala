import 'dart:io';

import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/cli_detection/application/project_import_service.dart';
import 'package:karmashala/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/features/projects/application/projects_controller.dart';
import 'package:karmashala_projects/store.dart';
import 'package:karmashala_projects/karmashala_projects.dart';
import 'package:karmashala/src/features/repositories/application/repository_discovery_provider.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';

void main() {
  late AppDatabase db;
  late FakeRepositoryDiscoveryService discovery;
  late ProviderContainer container;

  EnvironmentPath root(String path) =>
      EnvironmentPath(environmentId: localHostEnvironmentId, path: path);

  setUp(() {
    db = AppDatabase.memory();
    ensureLocalEnvironment(ExecutionEnvironmentDao(db), FixedClock(testTime));
    discovery = FakeRepositoryDiscoveryService(
      result: [DiscoveredRepository(name: 'app', path: root(r'C:\ws\app'))],
    );
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        repositoryDiscoveryServiceProvider.overrideWithValue(discovery),
        idGeneratorProvider.overrideWithValue(SequentialIdGenerator()),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        autoImportRunnerProvider.overrideWithValue(
          (_) async => const ImportSummary(),
        ),
      ],
    );
  });
  tearDown(() {
    container.dispose();
    db.close();
  });

  test('starts empty', () {
    expect(container.read(projectsControllerProvider), isEmpty);
  });

  test('createByDiscovery persists and refreshes the list', () async {
    await container
        .read(projectsControllerProvider.notifier)
        .createByDiscovery(name: 'Workspace', path: r'C:\ws');

    final projects = container.read(projectsControllerProvider);
    expect(projects.single.name, 'Workspace');
    expect(discovery.calls.single.path, r'C:\ws');
  });

  /// **A folder is somewhere to run, whether or not it is a clone.**
  ///
  /// The report: *"trying to start a new session in a project without git gives
  /// that error"* — "this project has nowhere recorded to run in yet". Creation
  /// has recorded the root since a folder was enough, but a project added
  /// before that has no checkout row at all, and every session-start surface
  /// read the empty table and refused. Nothing about the agent CLIs needs it:
  /// all three start in a plain directory.
  group('ensureRunLocation', () {
    late Directory folder;

    setUp(() {
      folder = Directory.systemTemp.createTempSync('ks-run-location');
      addTearDown(() => folder.deleteSync(recursive: true));
    });

    void addProject({required String path}) => ProjectDao(db).insert(
      Project(
        id: 'legacy',
        name: 'Plain folder',
        root: EnvironmentPath(
          environmentId: localHostEnvironmentId,
          path: path,
        ),
        createdAt: testTime,
      ),
    );

    test('records the project\'s own folder when nothing else is', () async {
      addProject(path: folder.path);

      final checkout = await container
          .read(projectsControllerProvider.notifier)
          .ensureRunLocation('legacy');

      expect(checkout.path.path, folder.path);
      expect(checkout.projectId, 'legacy');
      // Recorded, not conjured: every other surface reads the same row.
      expect(RepositoryDao(db).getByProject('legacy').single.id, checkout.id);
    });

    test('leaves a project that already has a checkout alone', () async {
      final created = await container
          .read(projectsControllerProvider.notifier)
          .createByDiscovery(name: 'Workspace', path: r'C:\ws');

      final before = RepositoryDao(db).getByProject(created.project.id);
      final checkout = await container
          .read(projectsControllerProvider.notifier)
          .ensureRunLocation(created.project.id);

      expect(checkout.id, before.single.id);
      expect(RepositoryDao(db).getByProject(created.project.id), hasLength(1));
    });

    test('refuses when the folder itself is not there, and names it', () async {
      addProject(path: r'C:\src\gone');

      await expectLater(
        container
            .read(projectsControllerProvider.notifier)
            .ensureRunLocation('legacy'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('Plain folder'), contains(r'C:\src\gone')),
          ),
        ),
      );
      expect(RepositoryDao(db).getByProject('legacy'), isEmpty);
    });
  });

  test('selected project exposes its repositories', () async {
    final result = await container
        .read(projectsControllerProvider.notifier)
        .createByDiscovery(name: 'Workspace', path: r'C:\ws');

    container
        .read(selectedProjectIdProvider.notifier)
        .select(result.project.id);

    final repos = container.read(selectedProjectRepositoriesProvider);
    expect(repos.single.name, 'app');
  });
}
