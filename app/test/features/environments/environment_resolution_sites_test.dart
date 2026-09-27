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
}
