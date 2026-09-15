import 'package:agent_cli/process.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/projects/application/project_service.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/projects/domain/project.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_discovery_service.dart';
import 'package:karmashala_git/repositories.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';

void main() {
  late AppDatabase db;
  late ProjectDao projectDao;
  late RepositoryDao repositoryDao;
  late FakeRepositoryDiscoveryService discovery;
  late ExecutionEnvironment windows;
  late ExecutionEnvironment wsl;

  EnvironmentPath local(String path) =>
      EnvironmentPath(environmentId: localHostEnvironmentId, path: path);

  ProjectService build() => ProjectService(
    projectDao: projectDao,
    repositoryDao: repositoryDao,
    discovery: discovery,
    ids: SequentialIdGenerator(),
    clock: FixedClock(testTime),
  );

  /// A project at `C:\ws` with two checkouts beneath it.
  Project seeded() {
    final project = Project(
      id: 'p1',
      name: 'Workspace',
      root: local(r'C:\ws'),
      createdAt: testTime,
    );
    projectDao.insert(project);
    repositoryDao.insert(
      Repository(
        id: 'r1',
        projectId: 'p1',
        name: 'app',
        path: local(r'C:\ws\app'),
        createdAt: testTime,
      ),
    );
    repositoryDao.insert(
      Repository(
        id: 'r2',
        projectId: 'p1',
        name: 'api',
        path: local(r'C:\ws\api'),
        createdAt: testTime,
      ),
    );
    return project;
  }

  setUp(() {
    db = AppDatabase.memory();
    windows = windowsEnv(id: localHostEnvironmentId);
    wsl = wslEnv();
    ExecutionEnvironmentDao(db)
      ..upsert(windows)
      ..upsert(wsl);
    projectDao = ProjectDao(db);
    repositoryDao = RepositoryDao(db);
    discovery = FakeRepositoryDiscoveryService();
  });
  tearDown(() => db.close());

  group('renaming', () {
    test('changes the name and touches nothing else', () async {
      final project = seeded();
      final result = await build().updateProject(project, name: 'Renamed');

      expect(result.project.name, 'Renamed');
      expect(projectDao.getById('p1')!.name, 'Renamed');
      expect(projectDao.getById('p1')!.root, project.root);
      expect(result.rebased, isEmpty);
      expect(discovery.calls, isEmpty, reason: 'a rename reads no disk');
    });

    test('a blank name is refused rather than saved', () async {
      final project = seeded();
      await expectLater(
        build().updateProject(project, name: '   '),
        throwsA(isA<RepositoryDiscoveryException>()),
      );
      expect(projectDao.getById('p1')!.name, 'Workspace');
    });
  });

  group('moving the root', () {
    test('rewrites the checkouts under it and keeps their ids', () async {
      final project = seeded();
      discovery.result = [
        DiscoveredRepository(name: 'app', path: local(r'C:\moved\app')),
        DiscoveredRepository(name: 'api', path: local(r'C:\moved\api')),
      ];

      final result = await build().updateProject(
        project,
        root: local(r'C:\moved'),
        target: windows,
        windows: windows,
      );

      expect(result.project.root.path, r'C:\moved');
      expect(result.rebased.map((r) => r.id), ['r1', 'r2']);
      expect(
        repositoryDao.getById('r1')!.path.path,
        r'C:\moved\app',
        reason: 'the same row, repointed — this is what sessions reference',
      );
      expect(repositoryDao.getById('r2')!.path.path, r'C:\moved\api');
      expect(
        result.discovered,
        isEmpty,
        reason: 'what discovery found was already rebased onto',
      );
      expect(repositoryDao.getByProject('p1'), hasLength(2));
    });

    test('a folder that cannot be read changes nothing at all', () async {
      final project = seeded();
      discovery.error = RepositoryDiscoveryException('Folder does not exist');

      await expectLater(
        build().updateProject(
          project,
          name: 'Renamed too',
          root: local(r'C:\gone'),
          target: windows,
          windows: windows,
        ),
        throwsA(isA<RepositoryDiscoveryException>()),
      );

      final after = projectDao.getById('p1')!;
      expect(after.root.path, r'C:\ws');
      expect(after.name, 'Workspace', reason: 'the rename went with it');
      expect(repositoryDao.getById('r1')!.path.path, r'C:\ws\app');
    });

    test('a checkout outside the old root is reported, not moved', () async {
      seeded();
      repositoryDao.insert(
        Repository(
          id: 'r3',
          projectId: 'p1',
          name: 'stray',
          path: local(r'D:\elsewhere\stray'),
          createdAt: testTime,
        ),
      );
      discovery.result = const [];

      final result = await build().updateProject(
        projectDao.getById('p1')!,
        root: local(r'C:\moved'),
        target: windows,
        windows: windows,
      );

      expect(result.rebased.map((r) => r.id), ['r1', 'r2']);
      expect(result.leftBehind.map((r) => r.id), ['r3']);
      expect(
        repositoryDao.getById('r3')!.path.path,
        r'D:\elsewhere\stray',
        reason: 'nothing here knows where it went, so it is left alone',
      );
    });

    test('a checkout found only under the new root is added', () async {
      final project = seeded();
      discovery.result = [
        DiscoveredRepository(name: 'app', path: local(r'C:\moved\app')),
        DiscoveredRepository(name: 'api', path: local(r'C:\moved\api')),
        DiscoveredRepository(name: 'docs', path: local(r'C:\moved\docs')),
      ];

      final result = await build().updateProject(
        project,
        root: local(r'C:\moved'),
        target: windows,
        windows: windows,
      );

      expect(result.discovered.map((r) => r.name), ['docs']);
      expect(repositoryDao.getByProject('p1'), hasLength(3));
    });

    test('the root itself as a checkout moves with the root', () async {
      final project = Project(
        id: 'p2',
        name: 'Single',
        root: local(r'C:\one'),
        createdAt: testTime,
      );
      projectDao.insert(project);
      repositoryDao.insert(
        Repository(
          id: 'r9',
          projectId: 'p2',
          name: 'one',
          path: local(r'C:\one'),
          createdAt: testTime,
        ),
      );
      discovery.result = const [];

      final result = await build().updateProject(
        project,
        root: local(r'C:\two'),
        target: windows,
        windows: windows,
      );

      expect(result.rebased.single.id, 'r9');
      expect(repositoryDao.getById('r9')!.path.path, r'C:\two');
    });

    test('a move between environments carries the checkouts across', () async {
      final project = seeded();
      discovery.result = const [];

      final result = await build().updateProject(
        project,
        root: EnvironmentPath(environmentId: wsl.id, path: '/home/me/ws'),
        target: wsl,
        windows: windows,
      );

      expect(result.project.root.environmentId, wsl.id);
      expect(result.rebased.map((r) => r.id), ['r1', 'r2']);
      final moved = repositoryDao.getById('r1')!;
      expect(moved.path.environmentId, wsl.id);
      expect(
        moved.path.path,
        '/home/me/ws/app',
        reason: 'joined in the new root\'s own spelling, not Windows\'',
      );
    });

    test('the same root spelled differently is not a move', () async {
      final project = seeded();
      final result = await build().updateProject(
        project,
        root: local(r'C:\WS\'),
        target: windows,
        windows: windows,
      );

      expect(discovery.calls, isEmpty, reason: 'nothing to discover');
      expect(result.rebased, isEmpty);
      expect(repositoryDao.getById('r1')!.path.path, r'C:\ws\app');
    });
  });

  group('the default checkout', () {
    test('is stored when it names a checkout of this project', () async {
      final project = seeded();
      final result = await build().updateProject(
        project,
        defaultRepositoryId: 'r2',
      );

      expect(result.project.defaultRepositoryId, 'r2');
      expect(projectDao.getById('p1')!.defaultRepositoryId, 'r2');
    });

    test('falls back rather than storing a checkout of another project', () async {
      final project = seeded();
      final result = await build().updateProject(
        project,
        defaultRepositoryId: 'someone-elses',
      );
      expect(result.project.defaultRepositoryId, isNull);
    });

    test('is cleared on request, which copyWith cannot express', () async {
      seeded();
      projectDao.insert(
        Project(
          id: 'p3',
          name: 'Chosen',
          root: local(r'C:\c'),
          createdAt: testTime,
          defaultRepositoryId: 'r1',
        ),
      );

      final result = await build().updateProject(
        projectDao.getById('p3')!,
        clearDefaultRepository: true,
      );
      expect(result.project.defaultRepositoryId, isNull);
      expect(projectDao.getById('p3')!.defaultRepositoryId, isNull);
    });

    test('survives a rename that says nothing about it', () async {
      seeded();
      projectDao.setDefaultRepository('p1', 'r2');

      final result = await build().updateProject(
        projectDao.getById('p1')!,
        name: 'Renamed',
      );
      expect(result.project.defaultRepositoryId, 'r2');
    });

    test('a retired checkout takes the default with it, not the project', () {
      seeded();
      projectDao.setDefaultRepository('p1', 'r2');
      expect(projectDao.getById('p1')!.defaultRepositoryId, 'r2');

      repositoryDao.delete('r2');

      final after = projectDao.getById('p1');
      expect(after, isNotNull, reason: 'the project outlives its checkout');
      expect(
        after!.defaultRepositoryId,
        isNull,
        reason: 'a dangling id would point the + button at nothing',
      );
    });
  });
}
