import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/cli_detection/application/project_import_service.dart';
import 'package:karmashala/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/features/projects/application/projects_controller.dart';
import 'package:karmashala/src/features/repositories/application/repository_discovery_provider.dart';
import 'package:karmashala/src/features/repositories/domain/discovered_repository.dart';
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
