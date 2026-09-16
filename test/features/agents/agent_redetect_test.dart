import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/agents/application/agent_installations_controller.dart';
import 'package:karmashala/src/features/agents/application/agent_providers.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// Two agents, neither declaring a Windows install location — these tests are
/// about what re-detection does with what it finds, not about where it looks.
const _registry = AgentRegistry([
  AgentDescriptor(
    id: AgentIds.claudeCode,
    displayName: 'Claude Code',
    binaries: AgentBinaries(windows: ['claude'], posix: ['claude']),
  ),
  AgentDescriptor(
    id: AgentIds.codex,
    displayName: 'Codex CLI',
    binaries: AgentBinaries(windows: ['codex'], posix: ['codex']),
  ),
]);

void main() {
  late AppDatabase db;
  late ProviderContainer container;

  /// Names currently "installed" on the fake host, mapped to their version.
  var installed = <String, String>{'claude': '2.1.0'};
  var reachable = true;

  FakeCommandRunner hostRunner() => FakeCommandRunner(
    responder: (req) {
      if (req.executable == 'bash') {
        final script = req.arguments.last;
        if (!reachable) {
          return const CommandResult(
            exitCode: 1,
            stdout: '',
            stderr: 'The distribution is not running.',
          );
        }
        if (script == 'exit 0') {
          return const CommandResult(exitCode: 0, stdout: '', stderr: '');
        }
        final name = script.split(' ').last;
        return installed.containsKey(name)
            ? CommandResult(
                exitCode: 0,
                stdout: '/usr/bin/$name\n',
                stderr: '',
              )
            : const CommandResult(exitCode: 1, stdout: '', stderr: '');
      }
      if (req.executable == 'where') {
        final name = req.arguments.first;
        return installed.containsKey(name)
            ? CommandResult(
                exitCode: 0,
                stdout: 'C:\\bin\\$name.exe\r\n',
                stderr: '',
              )
            : const CommandResult(exitCode: 1, stdout: '', stderr: '');
      }
      // A version probe of a located executable.
      final name = req.executable.split(RegExp(r'[\\/]')).last.split('.').first;
      return CommandResult(
        exitCode: 0,
        stdout: installed[name] ?? '',
        stderr: '',
      );
    },
  );

  setUp(() {
    installed = {'claude': '2.1.0'};
    reachable = true;
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        idGeneratorProvider.overrideWithValue(SequentialIdGenerator()),
        agentRegistryProvider.overrideWithValue(_registry),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(fallback: hostRunner()),
        ),
      ],
    );
  });
  tearDown(() {
    container.dispose();
    db.close();
  });

  AgentInstallationsController notifier() =>
      container.read(agentInstallationsControllerProvider.notifier);

  test('re-detect picks up an agent installed since the last scan', () async {
    await notifier().discoverAll();
    expect(container.read(agentInstallationsControllerProvider).length, 1);

    installed['codex'] = '0.151.0';
    final report = await notifier().discoverAll();

    expect(report.addedCount, 1);
    expect(report.foundCount, 2);
    expect(
      container
          .read(agentInstallationsControllerProvider)
          .map((i) => i.agentId)
          .toSet(),
      {AgentIds.claudeCode, AgentIds.codex},
    );
  });

  test('re-detect drops an agent that has been removed', () async {
    installed['codex'] = '0.151.0';
    await notifier().discoverAll();
    expect(container.read(agentInstallationsControllerProvider).length, 2);

    installed.remove('codex');
    final report = await notifier().discoverAll();

    expect(report.removedCount, 1);
    expect(report.foundCount, 1);
    expect(
      container.read(agentInstallationsControllerProvider).map((i) => i.agentId),
      [AgentIds.claudeCode],
    );
  });

  test('re-detect records a changed version in place', () async {
    await notifier().discoverAll();
    final before = container.read(agentInstallationsControllerProvider).single;
    expect(before.version, '2.1.0');

    installed['claude'] = '2.1.252';
    final report = await notifier().discoverAll();

    expect(report.updatedCount, 1);
    final after = container.read(agentInstallationsControllerProvider).single;
    expect(after.version, '2.1.252');
    expect(after.id, before.id, reason: 'the same installation, not a new row');
    expect(report.addedCount, 0);
    expect(report.removedCount, 0);
  });

  test('the report names what was NOT found', () async {
    final report = await notifier().discoverAll();

    expect(report.foundCount, 1);
    final windows = report.environments.single;
    expect(windows.missing, ['Codex CLI']);
    expect(report.summary, contains('Codex CLI'));
    expect(report.summary, contains('1 agent'));
  });

  test('a scan that finds nothing says so rather than claiming success', () async {
    installed.clear();
    final report = await notifier().discoverAll();

    expect(report.foundCount, 0);
    expect(report.summary.toLowerCase(), contains('no agents'));
  });

  test('an unreachable environment keeps its installations', () async {
    ExecutionEnvironmentDao(db).upsert(wslEnv());
    installed['codex'] = '0.151.0';
    await notifier().discoverAll();
    final wslInstalls = container
        .read(agentInstallationsControllerProvider)
        .where((i) => i.environmentId == 'wsl:Ubuntu')
        .length;
    expect(wslInstalls, 2);

    // The distro is stopped. Its agents did not vanish; we simply cannot see
    // them, and deleting them would be a lie dressed as a scan result.
    reachable = false;
    final report = await notifier().discoverAll();

    expect(
      container
          .read(agentInstallationsControllerProvider)
          .where((i) => i.environmentId == 'wsl:Ubuntu')
          .length,
      2,
    );
    final wsl = report.environments.firstWhere(
      (e) => e.environmentId == 'wsl:Ubuntu',
    );
    expect(wsl.reachable, isFalse);
    expect(report.removedCount, 0);
    expect(report.summary.toLowerCase(), contains('could not reach'));
  });

  test('re-detect clears the probe log so a stale miss is retried', () async {
    // The bug this exists for: the first scan recorded "codex: searched,
    // windows" and `discoverUnprobed` then skipped Windows on every launch,
    // so an agent installed later stayed invisible forever.
    await notifier().discoverAll();
    installed['codex'] = '0.151.0';
    expect((await notifier().discoverUnprobed()), isEmpty);

    final report = await notifier().discoverAll();
    expect(report.addedCount, 1);
  });
}
