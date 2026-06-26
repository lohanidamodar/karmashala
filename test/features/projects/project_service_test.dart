import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/features/environments/data/execution_environment_dao.dart';
import 'package:chitragupta/src/features/environments/domain/environment_path.dart';
import 'package:chitragupta/src/features/repositories/domain/discovered_repository.dart';
import 'package:chitragupta/src/features/environments/domain/local_environment.dart';
import 'package:chitragupta/src/features/projects/application/project_service.dart';
import 'package:chitragupta/src/features/projects/data/project_dao.dart';
import 'package:chitragupta/src/features/repositories/data/repository_dao.dart';
import 'package:chitragupta/src/features/repositories/data/repository_discovery_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';

void main() {
  late AppDatabase db;
  late ProjectDao projectDao;
  late RepositoryDao repositoryDao;
  late FakeRepositoryDiscoveryService discovery;

  EnvironmentPath root(String path) =>
      EnvironmentPath(environmentId: localWindowsEnvironmentId, path: path);

  ProjectService build() => ProjectService(
    projectDao: projectDao,
    repositoryDao: repositoryDao,
    discovery: discovery,
    ids: SequentialIdGenerator(),
    clock: FixedClock(testTime),
  );

  setUp(() {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(
      db,
    ).upsert(windowsEnv(id: localWindowsEnvironmentId));
    projectDao = ProjectDao(db);
    repositoryDao = RepositoryDao(db);
    discovery = FakeRepositoryDiscoveryService();
  });
  tearDown(() => db.close());

  test('persists the project and all discovered repositories', () async {
    discovery.result = [
      DiscoveredRepository(name: 'app', path: root(r'C:\ws\app')),
      DiscoveredRepository(name: 'api', path: root(r'C:\ws\api')),
    ];

    final result = await build().createProjectByDiscovery(
      name: 'Workspace',
      root: root(r'C:\ws'),
    );

    expect(result.project.name, 'Workspace');
    expect(result.repositories.map((r) => r.name), ['app', 'api']);
    expect(projectDao.getAll().single.name, 'Workspace');
    expect(repositoryDao.getByProject(result.project.id).length, 2);
  });

  test('does not persist a project when discovery fails', () async {
    discovery.error = RepositoryDiscoveryException('bad folder');

    await expectLater(
      build().createProjectByDiscovery(name: 'X', root: root(r'C:\missing')),
      throwsA(isA<RepositoryDiscoveryException>()),
    );
    expect(projectDao.getAll(), isEmpty);
  });

  test('rediscover only adds repositories not already recorded', () async {
    discovery.result = [
      DiscoveredRepository(name: 'app', path: root(r'C:\ws\app')),
    ];
    final created = await build().createProjectByDiscovery(
      name: 'W',
      root: root(r'C:\ws'),
    );

    discovery.result = [
      DiscoveredRepository(name: 'app', path: root(r'C:\ws\app')),
      DiscoveredRepository(name: 'api', path: root(r'C:\ws\api')),
    ];
    final added = await build().rediscover(created.project);

    expect(added.map((r) => r.name), ['api']);
    expect(repositoryDao.getByProject(created.project.id).length, 2);
  });
}
