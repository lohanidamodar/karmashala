import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/process/command_runner.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/agents/application/agent_installations_controller.dart';
import 'package:karmashala/src/features/agents/application/agent_providers.dart';
import 'package:karmashala/src/features/agents/domain/agent_ids.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
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

  // A sweep of the local host alone, answering `where <name>` however the case
  // at hand needs it. The local host has no reachability probe — it is the
  // machine running the code — so whatever this says is taken as evidence.
  group('an installation that ran sessions', () {
    late AppDatabase db;
    late ProviderContainer container;

    ProviderContainer containerFinding(Map<String, String> onPath) {
      db = AppDatabase.memory();
      ExecutionEnvironmentDao(db).upsert(windowsEnv());
      ProjectDao(db).insert(project());
      RepositoryDao(db).insert(repository());
      AgentInstallationDao(
        db,
      ).insert(agentInstallation(id: 'old', path: r'C:\old\claude.exe'));
      SessionDao(db).insert(session(agentInstallationId: 'old'));

      return ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          clockProvider.overrideWithValue(FixedClock(testTime)),
          idGeneratorProvider.overrideWithValue(SequentialIdGenerator()),
          hostEnvironmentProvider.overrideWithValue(const {}),
          commandRunnerFactoryProvider.overrideWithValue(
            FakeCommandRunnerFactory(
              fallback: FakeCommandRunner(
                responder: (req) {
                  if (req.executable != 'where') {
                    return const CommandResult(
                      exitCode: 0,
                      stdout: '3.0.0',
                      stderr: '',
                    );
                  }
                  final hit = onPath[req.arguments.first];
                  return hit == null
                      ? const CommandResult(exitCode: 1, stdout: '', stderr: '')
                      : CommandResult(exitCode: 0, stdout: hit, stderr: '');
                },
              ),
            ),
          ),
        ],
      );
    }

    tearDown(() {
      container.dispose();
      db.close();
    });

    String installationOfTheSession() =>
        db
                .query('SELECT agent_installation_id FROM sessions;')
                .single['agent_installation_id']
            as String;

    test(
      'survives a sweep that finds nothing, rather than blinding the app',
      () async {
        // The failure this is written for: `sessions.agent_installation_id` is
        // ON DELETE RESTRICT, so tidying away the row for an agent that is no
        // longer on PATH raised SqliteException(1811) out of the middle of the
        // sweep. The whole run died with it, and the app — which had two agents
        // installed and working — reported "Detection failed" and listed none.
        container = containerFinding(const {});

        final report = await container
            .read(agentInstallationsControllerProvider.notifier)
            .discoverAll();

        expect(report.environments.single.reachable, isTrue);
        expect(report.retainedCount, 1);
        expect(report.removedCount, 0);
        // Kept, so the session it ran can still say what ran it.
        expect(
          container.read(agentInstallationsControllerProvider),
          hasLength(1),
        );
        expect(installationOfTheSession(), 'old');
      },
    );

    test(
      'follows its agent to a new path, taking its sessions along',
      () async {
        container = containerFinding(const {
          'claude': 'C:\\new\\claude.exe\r\n',
        });

        final report = await container
            .read(agentInstallationsControllerProvider.notifier)
            .discoverAll();

        // One row, at the new path: the old one is gone rather than kept
        // alongside it as a second, dead Claude Code.
        final installations = container.read(
          agentInstallationsControllerProvider,
        );
        expect(installations.single.executable.path, r'C:\new\claude.exe');
        expect(report.removedCount, 1);
        expect(report.retainedCount, 0);
        // And the session moved with it, so it is still resumable.
        expect(installationOfTheSession(), installations.single.id);
      },
    );
  });
}
