import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/process/command_runner.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/agents/application/agent_installations_controller.dart';
import 'package:karmashala/src/features/agents/application/agent_providers.dart';
import 'package:karmashala/src/features/agents/domain/agent_ids.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

void main() {
  late AppDatabase db;
  late ProviderContainer container;

  // Both environments report only Claude installed.
  FakeCommandRunner claudeOnlyRunner() => FakeCommandRunner(
    responder: (req) {
      // Windows probes with `where <name>`; WSL probes through a login shell
      // as `bash -lc 'command -v <name>'`.
      final isWindowsLocate = req.executable == 'where';
      final isWslLocate =
          req.executable == 'bash' && req.arguments.first == '-lc';
      // A reachable environment answers the liveness probe a reconciling scan
      // runs before it will delete anything.
      if (isWslLocate && req.arguments.last == 'exit 0') {
        return const CommandResult(exitCode: 0, stdout: '', stderr: '');
      }
      if (isWindowsLocate || isWslLocate) {
        final target = isWslLocate
            ? req.arguments.last.split(' ').last
            : req.arguments.first;
        return target == 'claude'
            ? CommandResult(
                exitCode: 0,
                stdout: '/usr/bin/claude\n',
                stderr: '',
              )
            : const CommandResult(exitCode: 1, stdout: '', stderr: '');
      }
      return const CommandResult(exitCode: 0, stdout: '2.0.0', stderr: '');
    },
  );

  setUp(() {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db)
      ..upsert(windowsEnv())
      ..upsert(wslEnv());
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        idGeneratorProvider.overrideWithValue(SequentialIdGenerator()),
        // No host variables, so the descriptors' declared Windows install
        // paths expand to nothing and these tests probe PATH only.
        hostEnvironmentProvider.overrideWithValue(const {}),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(fallback: claudeOnlyRunner()),
        ),
      ],
    );
  });
  tearDown(() {
    container.dispose();
    db.close();
  });

  test('discovers the same agent independently per environment', () async {
    final report = await container
        .read(agentInstallationsControllerProvider.notifier)
        .discoverAll();

    expect(report.foundCount, 2);
    final installations = container.read(agentInstallationsControllerProvider);
    expect(installations.map((i) => i.environmentId).toSet(), {
      'windows',
      'wsl:Ubuntu',
    });
    expect(
      installations.every((i) => i.agentId == AgentIds.claudeCode),
      isTrue,
    );
    expect(installations.every((i) => i.version == '2.0.0'), isTrue);
  });

  test('re-running discovery does not duplicate installations', () async {
    final notifier = container.read(
      agentInstallationsControllerProvider.notifier,
    );
    await notifier.discoverAll();
    await notifier.discoverAll();
    expect(container.read(agentInstallationsControllerProvider).length, 2);
  });
}
