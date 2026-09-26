import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala/src/features/projects/application/project_service.dart';
import 'package:karmashala/src/features/workspaces/data/workspace_data.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

void main() {
  late AppDatabase db;
  late FakeDataServer server;
  late WorkspaceData workspace;
  late FakeRepositoryDiscoveryService discovery;

  EnvironmentPath root(String path) =>
      EnvironmentPath(environmentId: localHostEnvironmentId, path: path);

  ProjectService build({CommandRunnerFactory? runnerFactory}) => ProjectService(
    workspace: workspace,
    discovery: discovery,
    runnerFactory: runnerFactory,
  );

  setUp(() async {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db)
      ..upsert(windowsEnv(id: localHostEnvironmentId))
      ..upsert(wslEnv())
      ..upsert(sshEnvFixture());
    server = FakeDataServer();
    workspace = await workspaceOf(server);
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
    expect(server.projectRows.getAll().single.name, 'Workspace');
    expect(server.repositoryRows.getByProject(result.project.id).length, 2);
  });

  group('a folder that is not a clone', () {
    // Claude Code, Codex and Antigravity all start in a plain directory. A
    // project with no checkout row could not be given a session at all — the
    // New Session dialog could only say it had no Git repositories to run in.
    test('on another machine too, bound to that machine', () async {
      discovery.result = const [];

      final result = await build().createProjectForEnvironment(
        name: 'Scratch',
        windowsScanPath: r'\\wsl.localhost\Ubuntu\home\me\scratch',
        windows: windowsEnv(id: localHostEnvironmentId),
        target: wslEnv(),
      );

      expect(result.repositories.single.path, result.project.root);
      expect(result.repositories.single.path.environmentId, wslEnv().id);
    });
  });

  test('does not persist a project when discovery fails', () async {
    discovery.error = RepositoryDiscoveryException('bad folder');

    await expectLater(
      build().createProjectByDiscovery(name: 'X', root: root(r'C:\missing')),
      throwsA(isA<RepositoryDiscoveryException>()),
    );
    expect(server.projectRows.getAll(), isEmpty);
  });

  test(
    'rediscover scans a WSL project on the host and records WSL paths',
    () async {
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
        windows: windowsEnv(id: localHostEnvironmentId),
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
        windows: windowsEnv(id: localHostEnvironmentId),
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
        reason:
            'git for this project runs in WSL, so the row is spelled its way',
      );
      expect(
        server.repositoryRows.getByProject(created.project.id).length,
        2,
        reason: 'the root was already recorded and must not be added twice',
      );
    },
  );

  test('createProjectForEnvironment binds repos to a WSL target', () async {
    discovery.result = [
      DiscoveredRepository(name: 'app', path: root(r'C:\ws\app')),
    ];
    final result = await build().createProjectForEnvironment(
      name: 'Workspace',
      windowsScanPath: r'C:\ws',
      windows: windowsEnv(id: localHostEnvironmentId),
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
        windows: windowsEnv(id: localHostEnvironmentId),
        target: windowsEnv(id: localHostEnvironmentId),
      );
      expect(result.project.root.path, r'C:\ws');
      expect(result.repositories.single.path.environmentId, 'windows');
    },
  );

  group('repoNameFromUrl', () {
    test('extracts repo name from various git and github url formats', () {
      expect(
        repoNameFromUrl('https://github.com/owner/my-repo.git'),
        'my-repo',
      );
      expect(repoNameFromUrl('https://github.com/owner/my-repo'), 'my-repo');
      expect(repoNameFromUrl('https://github.com/owner/my-repo/'), 'my-repo');
      expect(repoNameFromUrl('git@github.com:owner/my-repo.git'), 'my-repo');
      expect(
        repoNameFromUrl('ssh://git@server:2222/org/my-project.git'),
        'my-project',
      );
    });
  });

  group('createProject on SSH target', () {
    test(
      'defaults target path to ~/karmashala/<repo> when path is empty',
      () async {
        final remote = sshEnvFixture();
        final runner = FakeCommandRunner(
          environmentId: remote.id,
          responder: (req) => const CommandResult(
            exitCode: 0,
            stdout: '/home/dev/karmashala/my-repo\n',
            stderr: '',
          ),
        );
        final factory = FakeCommandRunnerFactory(
          byEnvironmentId: {remote.id: runner},
        );

        discovery.result = [
          DiscoveredRepository(
            name: 'my-repo',
            path: EnvironmentPath(
              environmentId: remote.id,
              path: '/home/dev/karmashala/my-repo',
            ),
          ),
        ];

        final result = await build(runnerFactory: factory).createProject(
          name: 'my-repo',
          target: remote,
          targetPath: '',
          gitRepoUrl: 'https://github.com/owner/my-repo.git',
        );

        expect(result.project.name, 'my-repo');
        expect(result.project.environmentId, remote.id);
        expect(result.project.root.path, '/home/dev/karmashala/my-repo');
        expect(result.repositories.single.name, 'my-repo');
        expect(result.repositories.single.path.environmentId, remote.id);

        // Verify the clone command was executed
        expect(runner.requests.length, 1);
        expect(runner.requests.first.executable, 'sh');
        expect(runner.requests.first.arguments.last, contains('git clone'));
        expect(
          runner.requests.first.arguments.last,
          contains("TARGET=\"\$HOME\"/'karmashala/my-repo'"),
        );
      },
    );

    test(
      'verifies remote folder existence when git repo is not provided',
      () async {
        final remote = sshEnvFixture();
        final runner = FakeCommandRunner(
          environmentId: remote.id,
          responder: (req) => const CommandResult(
            exitCode: 0,
            stdout: '/home/dev/existing-folder\n',
            stderr: '',
          ),
        );
        final factory = FakeCommandRunnerFactory(
          byEnvironmentId: {remote.id: runner},
        );

        discovery.result = [
          DiscoveredRepository(
            name: 'existing-folder',
            path: EnvironmentPath(
              environmentId: remote.id,
              path: '/home/dev/existing-folder',
            ),
          ),
        ];

        final result = await build(runnerFactory: factory).createProject(
          name: 'existing-folder',
          target: remote,
          targetPath: '/home/dev/existing-folder',
        );

        expect(result.project.name, 'existing-folder');
        expect(result.project.environmentId, remote.id);
        expect(result.project.root.path, '/home/dev/existing-folder');
        expect(runner.requests.length, 1);
        expect(runner.requests.first.arguments.last, contains('cd'));
      },
    );
  });
}
