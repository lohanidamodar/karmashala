import 'package:agent_cli/process.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/agents/application/agent_installations_controller.dart';
import 'package:karmashala/src/features/agents/application/agent_providers.dart';
import 'package:karmashala/src/features/agents/data/agent_probe_log.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// The owner's machine, in miniature: `agy` is on the login PATH inside WSL and
/// nowhere on Windows, and `claude`/`codex` are found by neither call because
/// nothing should ever ask.
FakeCommandRunner agyInWslRunner() => FakeCommandRunner(
  responder: (req) {
    final isWindowsLocate = req.executable == 'where';
    final isPosixLocate =
        req.executable == 'bash' && req.arguments.first == '-lc';
    if (isPosixLocate && req.arguments.last == 'exit 0') {
      return const CommandResult(exitCode: 0, stdout: '', stderr: '');
    }
    if (isWindowsLocate || isPosixLocate) {
      final target = isPosixLocate
          ? req.arguments.last.split(' ').last
          : req.arguments.first;
      return target == 'agy' && isPosixLocate
          ? const CommandResult(
              exitCode: 0,
              stdout: '/home/dlohani/.local/bin/agy\n',
              stderr: '',
            )
          : const CommandResult(exitCode: 1, stdout: '', stderr: '');
    }
    return const CommandResult(exitCode: 0, stdout: '1.1.22', stderr: '');
  },
);

void main() {
  late FakeDataServer server;
  late ProviderContainer container;
  late FakeCommandRunner runner;

  /// The four rows the owner's workspace actually held: two agents, two
  /// environments, all stamped long before `antigravity` joined the registry.
  void seedPreAntigravityInstallations() {
    final dao = server.installationRows;
    var n = 0;
    for (final agentId in [AgentIds.claudeCode, AgentIds.codex]) {
      for (final environmentId in ['windows', 'wsl:archlinux']) {
        dao.insert(
          agentInstallation(
            id: 'a${n++}',
            agentId: agentId,
            environmentId: environmentId,
            path: '/home/dlohani/.local/bin/$agentId',
          ),
        );
      }
    }
  }

  setUp(() async {
    runner = agyInWslRunner();
    server = FakeDataServer();
    server.environmentRows
      ..upsert(windowsEnv())
      ..upsert(wslEnv(id: 'wsl:archlinux', distro: 'archlinux'));
    final data = await server.override();
    container = ProviderContainer(
      overrides: [
        data,
        clockProvider.overrideWithValue(FixedClock(testTime)),
        idGeneratorProvider.overrideWithValue(SequentialIdGenerator()),
        // No host variables, so the descriptors' declared Windows install
        // paths expand to nothing and these tests probe PATH only.
        hostEnvironmentProvider.overrideWithValue(const {}),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(fallback: runner),
        ),
      ],
    );
  });
  tearDown(() => container.dispose());

  /// Every executable name a locate request asked about, in order.
  List<String> located() => [
    for (final req in runner.requests)
      if (req.executable == 'where')
        req.arguments.first
      else if (req.executable == 'bash' && req.arguments.first == '-lc')
        req.arguments.last.split(' ').last,
  ];

  test(
    'an agent added by an upgrade is found without a manual rescan',
    () async {
      seedPreAntigravityInstallations();

      final found = await container
          .read(agentInstallationsControllerProvider.notifier)
          .discoverUnprobed();

      expect(found.map((i) => i.agentId), [AgentIds.antigravity]);
      expect(found.single.environmentId, 'wsl:archlinux');
      expect(found.single.executable.path, '/home/dlohani/.local/bin/agy');
      expect(found.single.version, '1.1.22');
      expect(
        container.read(agentInstallationsControllerProvider).length,
        5,
        reason: 'the four seeded rows plus the one nobody had looked for',
      );
    },
  );

  test('an agent already installed here is never probed', () async {
    seedPreAntigravityInstallations();

    await container
        .read(agentInstallationsControllerProvider.notifier)
        .discoverUnprobed();

    // An installation row is itself proof somebody looked. Re-probing it would
    // spawn a process per agent per environment on every single launch.
    expect(located().toSet(), {'agy'});
    expect(
      located().length,
      2,
      reason: 'once per unprobed agent per environment, no more',
    );
  });

  test('an agent looked for and absent is not looked for again', () async {
    seedPreAntigravityInstallations();
    final notifier = container.read(
      agentInstallationsControllerProvider.notifier,
    );
    await notifier.discoverUnprobed();
    runner.requests.clear();

    final second = await notifier.discoverUnprobed();

    expect(second, isEmpty);
    expect(
      runner.requests,
      isEmpty,
      reason: 'a miss is recorded, so the next launch spawns nothing at all',
    );
    await pumpEventQueue();
    expect(
      AgentProbeLog(server.store).hasProbed(AgentIds.antigravity, 'windows'),
      isTrue,
    );
  });

  test(
    'a remote host is not dialled, and is not recorded as searched',
    () async {
      server.environmentRows.upsert(sshEnvFixture());
      seedPreAntigravityInstallations();

      await container
          .read(agentInstallationsControllerProvider.notifier)
          .discoverUnprobed();

      // Startup must not reach out to every saved machine. The pair stays
      // unrecorded because it was skipped, not searched — "Discover agents" on
      // that environment still has work to do.
      await pumpEventQueue();
      expect(
        AgentProbeLog(server.store).hasProbed(AgentIds.antigravity, 'ssh:h1'),
        isFalse,
      );
    },
  );

  test(
    'a workspace that has never discovered anything probes everything',
    () async {
      final found = await container
          .read(agentInstallationsControllerProvider.notifier)
          .discoverUnprobed();

      expect(located().toSet(), {'claude', 'codex', 'agy'});
      expect(found.map((i) => i.agentId), [AgentIds.antigravity]);
    },
  );
}
