import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/environments/domain/environment_path.dart';
import 'package:karmashala/src/features/repositories/domain/discovered_repository.dart';
import 'package:karmashala/src/features/environments/domain/local_environment.dart';
import 'package:karmashala/src/features/projects/application/project_service.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_discovery_service.dart';
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
    ExecutionEnvironmentDao(db)
      ..upsert(windowsEnv(id: localWindowsEnvironmentId))
      ..upsert(wslEnv());
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
    final added = await build().rediscover(
      created.project,
      projectEnvironment: windowsEnv(id: localWindowsEnvironmentId),
      windows: windowsEnv(id: localWindowsEnvironmentId),
    );

    expect(added.map((r) => r.name), ['api']);
    expect(repositoryDao.getByProject(created.project.id).length, 2);
  });

  test('rediscover matches a recorded repository however it is spelled', () async {
    // B7: the match used to be string equality on the whole `EnvironmentPath`,
    // so a scanner that reported `C:/ws/app` — or the same path with a trailing
    // separator — inserted a second row for a checkout already in the table.
    discovery.result = [
      DiscoveredRepository(name: 'app', path: root(r'C:\ws\app')),
    ];
    final created = await build().createProjectByDiscovery(
      name: 'W',
      root: root(r'C:\ws'),
    );

    discovery.result = [
      DiscoveredRepository(name: 'app', path: root('C:/ws/app')),
      DiscoveredRepository(name: 'api', path: root(r'C:\ws\api\')),
      DiscoveredRepository(name: 'App', path: root(r'C:\WS\APP')),
    ];
    final added = await build().rediscover(
      created.project,
      projectEnvironment: windowsEnv(id: localWindowsEnvironmentId),
      windows: windowsEnv(id: localWindowsEnvironmentId),
    );

    expect(added.map((r) => r.name), [
      'api',
    ], reason: 'three spellings of one Windows checkout are one checkout');
    expect(repositoryDao.getByProject(created.project.id).length, 2);
  });

  test('rediscover scans a WSL project on the host and records WSL paths', () async {
    // The bug this pins down, reported three times from the shipped app: the
    // GitHub and Changes panels described the hub a session launched in and
    // never the clone inside it. `rediscover` handed the project's own root to
    // discovery, and discovery is `dart:io` on Windows — so for a project
    // rooted at `/mnt/c/ws` it asked Windows for a path Windows has never
    // heard of and threw. The rescan could not run, so the row for the nested
    // checkout could never be written, so the picker had one entry to offer.
    discovery.result = [
      DiscoveredRepository(name: 'ws', path: root(r'C:\ws')),
    ];
    final created = await build().createProjectForEnvironment(
      name: 'W',
      windowsScanPath: r'C:\ws',
      windows: windowsEnv(id: localWindowsEnvironmentId),
      target: wslEnv(),
    );
    discovery.calls.clear();

    discovery.result = [
      DiscoveredRepository(name: 'ws', path: root(r'C:\ws')),
      DiscoveredRepository(name: 'app', path: root(r'C:\ws\projects\app')),
    ];
    final added = await build().rediscover(
      created.project,
      projectEnvironment: wslEnv(),
      windows: windowsEnv(id: localWindowsEnvironmentId),
    );

    expect(
      discovery.calls.single.path,
      r'C:\ws',
      reason: 'the scan runs on the host, which is the only place it can run',
    );
    expect(added.map((r) => r.name), ['app']);
    expect(added.single.path.environmentId, 'wsl:Ubuntu');
    expect(
      added.single.path.path,
      '/mnt/c/ws/projects/app',
      reason: 'git for this project runs in WSL, so the row is spelled its way',
    );
    expect(
      repositoryDao.getByProject(created.project.id).length,
      2,
      reason: 'the root was already recorded and must not be added twice',
    );
  });

  test('createProjectForEnvironment binds repos to a WSL target', () async {
    discovery.result = [
      DiscoveredRepository(name: 'app', path: root(r'C:\ws\app')),
    ];
    final result = await build().createProjectForEnvironment(
      name: 'Workspace',
      windowsScanPath: r'C:\ws',
      windows: windowsEnv(id: localWindowsEnvironmentId),
      target: wslEnv(),
    );

    // The scan ran on the Windows path; results were bound to the WSL namespace.
    expect(discovery.calls.single.path, r'C:\ws');
    expect(result.project.root.environmentId, 'wsl:Ubuntu');
    expect(result.project.root.path, '/mnt/c/ws');
    expect(result.repositories.single.path.environmentId, 'wsl:Ubuntu');
    expect(result.repositories.single.path.path, '/mnt/c/ws/app');
  });

  test(
    'createProjectForEnvironment keeps Windows paths for a Windows target',
    () async {
      discovery.result = [
        DiscoveredRepository(name: 'app', path: root(r'C:\ws\app')),
      ];
      final result = await build().createProjectForEnvironment(
        name: 'Workspace',
        windowsScanPath: r'C:\ws',
        windows: windowsEnv(id: localWindowsEnvironmentId),
        target: windowsEnv(id: localWindowsEnvironmentId),
      );
      expect(result.project.root.path, r'C:\ws');
      expect(result.repositories.single.path.environmentId, 'windows');
    },
  );
}
