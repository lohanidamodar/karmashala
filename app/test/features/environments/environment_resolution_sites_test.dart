import 'package:karmashala/src/core/data/data_client.dart';
import 'package:karmashala/src/core/data/data_providers.dart';
import 'package:karmashala/src/features/agents/data/agents_data.dart';
import 'package:karmashala/src/features/environments/data/environments_data.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:agent_cli/stream.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/cli_detection/data/agent_store_servers.dart';
import 'package:karmashala/src/features/environments/application/environment_resolver.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/features/git/application/changes_providers.dart';
import 'package:karmashala/src/features/git/application/changes_service.dart';
import 'package:karmashala_git/worktrees.dart';
import 'package:karmashala_git/git.dart';
import 'package:karmashala/src/features/github/application/github_providers.dart';
import 'package:karmashala_git/github.dart';
import 'package:karmashala/src/features/projects/application/projects_controller.dart';
import 'package:karmashala/src/features/repositories/data/repository_discovery_service.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fixtures.dart';
import '../../support/fake_data_server.dart';

/// **Every launch path refuses an unresolvable environment in the same words.**
///
/// The words are `ExecutionEnvironmentResolver`'s, and each site below reaches
/// them rather than carrying a sentence of its own — which is the whole point
/// of the resolver, and the only thing that keeps a sixth launch path from
/// inventing a sixth phrasing. What each site does *with* the refusal is its
/// own business and unchanged: git throws a `GitException`, an adapter throws,
/// a pool returns null, a probe answers `unknown`.
void main() {
  late FakeDataServer server;
  late DataClient client;
  late FakeCommandRunner runner;

  /// A checkout filed under an environment the workspace no longer has.
  const gone = EnvironmentPath(environmentId: 'wsl:Gone', path: '/home/me/app');

  /// What every one of these sites must end up saying.
  const words = 'Unknown environment: wsl:Gone';

  setUp(() async {
    server = FakeDataServer()..environmentRows.upsert(windowsEnv());
    client = await server.connect();
    runner = FakeCommandRunner();
  });

  FakeCommandRunnerFactory factory() =>
      FakeCommandRunnerFactory(fallback: runner);

  /// The `RunnerResolver` the app composes: the resolver's refusal first, then
  /// the factory. The adapters take this instead of resolving for themselves,
  /// so it is where their words come from now.
  RunnerResolver appRunnerResolver() {
    final c = ProviderContainer(
      overrides: [
        dataClientProvider.overrideWithValue(client),
        commandRunnerFactoryProvider.overrideWithValue(factory()),
      ],
    );
    addTearDown(c.dispose);
    return c.read(runnerResolverProvider);
  }

  Matcher saysSo<T>() =>
      throwsA(isA<T>().having((e) => '$e', 'message', contains(words)));

  group('git', () {
    test('WorktreeService.list refuses, and spawns nothing', () async {
      final service = WorktreeService(
        runnerFactory: factory(),
        environmentOf: worktreeEnvironmentOf(EnvironmentsData(client)),
      );

      // Synchronous: the refusal happens before any future is made.
      expect(() => service.list(gone), saysSo<GitException>());
      expect(runner.requests, isEmpty);
    });

    test('WorktreeService.createForSession refuses before git runs', () async {
      final service = WorktreeService(
        runnerFactory: factory(),
        environmentOf: worktreeEnvironmentOf(EnvironmentsData(client)),
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
        environmentDao: EnvironmentsData(client),
      );

      expect(() => service.changes(gone), saysSo<GitException>());
      expect(runner.requests, isEmpty);
    });

    test('GitHubReviewService refuses', () async {
      final service = GitHubReviewService(
        runnerFactory: factory(),
        environmentDao: EnvironmentsData(client),
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
      final adapter = ClaudeCodeChatProtocol(runnerFor: appRunnerResolver());
      expect(() => adapter.start(launch()), saysSo<StateError>());
    });

    test('Codex refuses', () {
      final adapter = CodexChatProtocol(runnerFor: appRunnerResolver());
      expect(() => adapter.start(launch()), saysSo<StateError>());
    });

    test('Antigravity refuses', () {
      final adapter = AntigravityChatProtocol(runnerFor: appRunnerResolver());
      expect(() => adapter.start(launch()), saysSo<StateError>());
    });

    test('an agent with no protocol refuses', () {
      final adapter = GenericChatProtocol(
        agentId: 'roverCli',
        launch: const AgentLaunchSpec(),
        runnerFor: appRunnerResolver(),
      );
      expect(() => adapter.start(launch()), saysSo<StateError>());
    });
  });

  test(
    'AgentStoreServers hands out nothing for an environment that is gone',
    () {
      final pool = AgentStoreServers(
        runnerFactory: factory(),
        environments: EnvironmentsData(client),
        installations: AgentInstallationsData(client),
      );

      expect(pool.forEnvironment(gone.environmentId, AgentIds.codex), isNull);
      expect(pool.openConnections, 0);
      expect(runner.startRequests, isEmpty);
    },
  );

  test('repository discovery runs no remote scan for an environment that is '
      'gone', () async {
    final service = EnvironmentAwareRepositoryDiscoveryService(
      localDiscovery: const LocalRepositoryDiscoveryService(),
      runnerFactory: factory(),
      environments: EnvironmentsData(client),
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
    Future<ProviderContainer> container() async {
      final c = ProviderContainer(
        overrides: [
          await server.override(),
          commandRunnerFactoryProvider.overrideWithValue(factory()),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    test(
      'the git-presence probe answers unknown rather than guessing',
      () async {
        expect(
          await (await container()).read(
            checkoutGitPresenceProvider(gone).future,
          ),
          GitPresence.unknown,
        );
        expect(runner.requests, isEmpty);
      },
    );

    test('creating a project on an environment that is gone refuses', () async {
      server
        ..projectRows.insert(project())
        ..repositoryRows.insert(repository());

      await expectLater(
        (await container())
            .read(projectsControllerProvider.notifier)
            .createProject(
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
