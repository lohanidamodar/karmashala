import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/agents/data/antigravity_adapter.dart';
import 'package:karmashala/src/features/agents/data/claude_code_adapter.dart';
import 'package:karmashala/src/features/agents/data/codex_adapter.dart';
import 'package:karmashala/src/features/agents/data/generic_agent_adapter.dart';
import 'package:karmashala/src/features/agents/domain/agent_adapter.dart';
import 'package:karmashala/src/features/agents/domain/agent_descriptor.dart';
import 'package:karmashala/src/features/cli_detection/data/codex_app_servers.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/environments/domain/environment_path.dart';
import 'package:karmashala/src/features/git/application/changes_providers.dart';
import 'package:karmashala/src/features/git/application/changes_service.dart';
import 'package:karmashala/src/features/git/application/worktree_service.dart';
import 'package:karmashala/src/features/git/data/git_service.dart';
import 'package:karmashala/src/features/git/domain/git_presence.dart';
import 'package:karmashala/src/features/github/application/github_providers.dart';
import 'package:karmashala/src/features/github/data/github_service.dart';
import 'package:karmashala/src/features/projects/application/projects_controller.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_discovery_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fixtures.dart';

/// **Every launch path refuses an unresolvable environment in the same words.**
///
/// The words are `ExecutionEnvironmentResolver`'s, and each site below reaches
/// them rather than carrying a sentence of its own — which is the whole point
/// of the resolver, and the only thing that keeps a sixth launch path from
/// inventing a sixth phrasing. What each site does *with* the refusal is its
/// own business and unchanged: git throws a `GitException`, an adapter throws,
/// a pool returns null, a probe answers `unknown`.
void main() {
  late AppDatabase db;
  late FakeCommandRunner runner;

  /// A checkout filed under an environment the workspace no longer has.
  const gone = EnvironmentPath(environmentId: 'wsl:Gone', path: '/home/me/app');

  /// What every one of these sites must end up saying.
  const words = 'Unknown environment: wsl:Gone';

  setUp(() {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    runner = FakeCommandRunner();
  });
  tearDown(() => db.close());

  FakeCommandRunnerFactory factory() =>
      FakeCommandRunnerFactory(fallback: runner);

  Matcher saysSo<T>() =>
      throwsA(isA<T>().having((e) => '$e', 'message', contains(words)));

  group('git', () {
    test('WorktreeService.list refuses, and spawns nothing', () async {
      final service = WorktreeService(
        runnerFactory: factory(),
        environmentDao: ExecutionEnvironmentDao(db),
      );

      // Synchronous: the refusal happens before any future is made.
      expect(() => service.list(gone), saysSo<GitException>());
      expect(runner.requests, isEmpty);
    });

    test('WorktreeService.createForSession refuses before git runs', () async {
      final service = WorktreeService(
        runnerFactory: factory(),
        environmentDao: ExecutionEnvironmentDao(db),
      );

      await expectLater(
        service.createForSession(
          repo: gone,
          worktreeName: 's1',
          branch: 'session/s1',
        ),
        saysSo<GitException>(),
      );
      expect(runner.requests, isEmpty);
    });

    test('ChangesService refuses', () async {
      final service = ChangesService(
        runnerFactory: factory(),
        environmentDao: ExecutionEnvironmentDao(db),
      );

      expect(() => service.changes(gone), saysSo<GitException>());
      expect(runner.requests, isEmpty);
    });

    test('GitHubReviewService refuses', () async {
      final service = GitHubReviewService(
        runnerFactory: factory(),
        environmentDao: ExecutionEnvironmentDao(db),
      );

      expect(() => service.repository(gone), saysSo<GitHubException>());
      expect(runner.requests, isEmpty);
    });
  });

  group('agent adapters', () {
    AgentLaunch launch() => AgentLaunch(
      workingDirectory: gone,
      installation: agentInstallation(environmentId: gone.environmentId),
    );

    test('Claude Code refuses', () {
      final adapter = ClaudeCodeAdapter(
        runnerFactory: factory(),
        environmentDao: ExecutionEnvironmentDao(db),
      );
      expect(() => adapter.start(launch()), saysSo<StateError>());
    });

    test('Codex refuses', () {
      final adapter = CodexAdapter(
        runnerFactory: factory(),
        environmentDao: ExecutionEnvironmentDao(db),
      );
      expect(() => adapter.start(launch()), saysSo<StateError>());
    });

    test('Antigravity refuses', () {
      final adapter = AntigravityAdapter(
        runnerFactory: factory(),
        environmentDao: ExecutionEnvironmentDao(db),
      );
      expect(() => adapter.start(launch()), saysSo<StateError>());
    });

    test('an agent with no protocol refuses', () {
      final adapter = GenericAgentAdapter(
        agentId: 'roverCli',
        launch: const AgentLaunchSpec(),
        runnerFactory: factory(),
        environmentDao: ExecutionEnvironmentDao(db),
      );
      expect(() => adapter.start(launch()), saysSo<StateError>());
    });
  });

  test('CodexAppServers hands out nothing for an environment that is gone', () {
    final pool = CodexAppServers(
      runnerFactory: factory(),
      environments: ExecutionEnvironmentDao(db),
      installations: AgentInstallationDao(db),
    );

    expect(pool.forEnvironment(gone.environmentId), isNull);
    expect(pool.openConnections, 0);
    expect(runner.startRequests, isEmpty);
  });

  test('repository discovery runs no remote scan for an environment that is '
      'gone', () async {
    final service = EnvironmentAwareRepositoryDiscoveryService(
      localDiscovery: const LocalRepositoryDiscoveryService(),
      runnerFactory: factory(),
      environments: ExecutionEnvironmentDao(db),
    );

    // Unchanged behaviour: an environment it cannot name falls to the local
    // walk, which answers for this host. What must not happen is an `sh` sent
    // into a distribution nothing names.
    await expectLater(
      service.discover(gone),
      throwsA(isA<RepositoryDiscoveryException>()),
    );
    expect(runner.requests, isEmpty);
  });

  group('through providers', () {
    ProviderContainer container() {
      final c = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          commandRunnerFactoryProvider.overrideWithValue(factory()),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    test('the git-presence probe answers unknown rather than guessing',
        () async {
      expect(
        await container().read(checkoutGitPresenceProvider(gone).future),
        GitPresence.unknown,
      );
      expect(runner.requests, isEmpty);
    });

    test('creating a project on an environment that is gone refuses', () async {
      ProjectDao(db).insert(project());
      RepositoryDao(db).insert(repository());

      await expectLater(
        container().read(projectsControllerProvider.notifier).createProject(
              name: 'Demo',
              targetEnvironmentId: gone.environmentId,
              folderPath: '/home/me/demo',
            ),
        saysSo<StateError>(),
      );
      expect(runner.requests, isEmpty);
    });
  });
}
