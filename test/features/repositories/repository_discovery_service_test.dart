import 'dart:io';

import 'package:karmashala_store/database.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_discovery_service.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../support/fake_command_runner.dart';
import '../../support/fixtures.dart';
import '../../support/temp_directory.dart';

void main() {
  late Directory tmp;
  const service = LocalRepositoryDiscoveryService();

  setUp(() => tmp = Directory.systemTemp.createTempSync('karmashala_disc_'));
  tearDown(() => removeTempDirectory(tmp));

  EnvironmentPath rootAt(String path) =>
      EnvironmentPath(environmentId: 'windows', path: path);

  void makeRepoDir(String relative) {
    Directory(p.join(tmp.path, relative, '.git')).createSync(recursive: true);
  }

  test('discovers a repo marked by a .git directory', () async {
    makeRepoDir('app');
    final found = await service.discover(rootAt(tmp.path));
    expect(found.map((r) => r.name), ['app']);
    expect(found.single.path.environmentId, 'windows');
  });

  test('discovers a repo marked by a .git FILE (worktree/submodule)', () async {
    final repo = Directory(p.join(tmp.path, 'wt'))..createSync(recursive: true);
    File(p.join(repo.path, '.git')).writeAsStringSync('gitdir: ../.git/wt');
    final found = await service.discover(rootAt(tmp.path));
    expect(found.map((r) => r.name), ['wt']);
  });

  test('finds sibling and nested repos, including inside a repo', () async {
    makeRepoDir('a');
    makeRepoDir(p.join('group', 'b'));
    // A repository inside a repository is still a repository. A hub repo whose
    // folder holds a dozen clones used to report exactly one row, leaving every
    // session in a sub-folder with nowhere to hang but the hub's own.
    makeRepoDir(p.join('a', 'nested'));
    final found = await service.discover(rootAt(tmp.path));
    // Sorted by path: `a`, then `a/nested`, then `group/b`.
    expect(found.map((r) => r.name).toList(), ['a', 'nested', 'b']);
  });

  test('does not walk into node_modules and friends', () async {
    // The cost of descending into repositories, paid back: the folders that
    // make a scan unaffordable are the ones nobody wants a row for anyway.
    makeRepoDir(p.join('app', 'node_modules', 'left-pad'));
    makeRepoDir(p.join('app', 'build', 'staged'));
    makeRepoDir('app');
    final found = await service.discover(rootAt(tmp.path));
    expect(found.map((r) => r.name), ['app']);
  });

  test('respects maxDepth', () async {
    makeRepoDir(p.join('one', 'two', 'three', 'deep'));
    final shallow = await service.discover(rootAt(tmp.path), maxDepth: 2);
    expect(shallow, isEmpty);
    final deep = await service.discover(rootAt(tmp.path), maxDepth: 6);
    expect(deep.map((r) => r.name), ['deep']);
  });

  test('ignores non-repository folders', () async {
    Directory(p.join(tmp.path, 'plain')).createSync(recursive: true);
    final found = await service.discover(rootAt(tmp.path));
    expect(found, isEmpty);
  });

  test('throws a clear error when the root does not exist', () async {
    expect(
      () => service.discover(rootAt(p.join(tmp.path, 'nope'))),
      throwsA(isA<RepositoryDiscoveryException>()),
    );
  });

  group('environment-aware discovery', () {
    late AppDatabase db;

    setUp(() => db = AppDatabase.memory());
    tearDown(() => db.close());

    EnvironmentAwareRepositoryDiscoveryService remoteService(
      FakeCommandRunner runner,
    ) {
      final remote = sshEnvFixture();
      final environments = ExecutionEnvironmentDao(db)..upsert(remote);
      return EnvironmentAwareRepositoryDiscoveryService(
        localDiscovery: const LocalRepositoryDiscoveryService(),
        runnerFactory: FakeCommandRunnerFactory(
          byEnvironmentId: {remote.id: runner},
        ),
        environments: environments,
      );
    }

    test('one remote scan finds roots and prunes dependency trees', () async {
      final runner = FakeCommandRunner(
        environmentId: 'ssh:h1',
        responder: (_) => const CommandResult(
          exitCode: 0,
          stdout:
              '/srv/work/.git\n'
              '/srv/work/apps/client/.git\n'
              '/srv/work/node_modules/vendor/.git\n',
          stderr: '',
        ),
      );

      final found = await remoteService(runner).discover(
        const EnvironmentPath(environmentId: 'ssh:h1', path: '/srv/work'),
        maxDepth: 2,
      );

      expect(found.map((repo) => repo.path.path), [
        '/srv/work',
        '/srv/work/apps/client',
      ]);
      expect(runner.requests, hasLength(1));
      final script = runner.requests.single.arguments.last;
      expect(script, contains('-maxdepth 3'));
      expect(script, contains("-name 'node_modules'"));
      expect(script, contains('-prune'));
    });

    test('a failed remote scan is not mistaken for an empty project', () async {
      final runner = FakeCommandRunner(
        environmentId: 'ssh:h1',
        responder: (_) => const CommandResult(
          exitCode: 2,
          stdout: '',
          stderr: 'Repository root does not exist: /missing',
        ),
      );

      await expectLater(
        remoteService(runner).discover(
          const EnvironmentPath(environmentId: 'ssh:h1', path: '/missing'),
        ),
        throwsA(isA<RepositoryDiscoveryException>()),
      );
      expect(runner.requests, hasLength(1));
    });

    test('WSL paths are scanned inside their distribution', () async {
      final environment = wslEnv();
      final environments = ExecutionEnvironmentDao(db)..upsert(environment);
      final runner = FakeCommandRunner(environmentId: environment.id);
      final service = EnvironmentAwareRepositoryDiscoveryService(
        localDiscovery: const LocalRepositoryDiscoveryService(),
        runnerFactory: FakeCommandRunnerFactory(
          byEnvironmentId: {environment.id: runner},
        ),
        environments: environments,
      );

      await service.discover(
        EnvironmentPath(environmentId: environment.id, path: '/src/work'),
      );

      expect(runner.requests, hasLength(1));
      expect(runner.requests.single.executable, 'sh');
    });
  });
}
