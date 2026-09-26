import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/environments/application/environment_health.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fixtures.dart';

/// Whether an execution environment can actually be used: can we run git in it,
/// and did we find any agents there.
///
/// Untested until Loop 48, which matters because this is the screen a user
/// reads when *nothing works* — its job is to be right about why.
void main() {
  late AppDatabase db;
  late ExecutionEnvironmentDao environments;
  late AgentInstallationDao installations;

  setUp(() {
    db = AppDatabase.memory();
    environments = ExecutionEnvironmentDao(db);
    installations = AgentInstallationDao(db);
  });
  tearDown(() => db.close());

  EnvironmentHealthService serviceWith(ProviderContainer container) =>
      container.read(environmentHealthServiceProvider);

  test(
    'a reachable environment with agents is healthy, and reports git',
    () async {
      environments.upsert(windowsEnv());
      installations.insert(agentInstallation());
      final container = _container(
        db,
        FakeCommandRunnerFactory(
          fallback: FakeCommandRunner(
            responder: (_) => const CommandResult(
              exitCode: 0,
              stdout: 'git version 2.51.0.windows.1\n',
              stderr: '',
            ),
          ),
        ),
      );
      addTearDown(container.dispose);

      final health = await serviceWith(container).check(windowsEnv());

      expect(health.level, HealthLevel.healthy);
      expect(health.gitVersion, 'git version 2.51.0.windows.1');
      expect(health.summary, '1 coding agent ready.');
      expect(health.installations, hasLength(1));
    },
  );

  test('the agent count is pluralised', () async {
    environments.upsert(windowsEnv());
    installations
      ..insert(agentInstallation(id: 'a1'))
      ..insert(
        agentInstallation(
          id: 'a2',
          agentId: AgentIds.codex,
          path: r'C:\bin\codex.exe',
        ),
      );
    final container = _container(db, _okFactory());
    addTearDown(container.dispose);

    final health = await serviceWith(container).check(windowsEnv());

    expect(health.summary, '2 coding agents ready.');
  });

  test('reachable but with no agents is a warning, not a failure', () async {
    environments.upsert(windowsEnv());
    final container = _container(db, _okFactory());
    addTearDown(container.dispose);

    final health = await serviceWith(container).check(windowsEnv());

    expect(health.level, HealthLevel.warning);
    expect(health.summary, 'Reachable, but no coding agents were discovered.');
    expect(health.installations, isEmpty);
  });

  test('a non-zero git exit is failed, and quotes what git said', () async {
    environments.upsert(wslEnv());
    final container = _container(
      db,
      FakeCommandRunnerFactory(
        fallback: FakeCommandRunner(
          responder: (_) => const CommandResult(
            exitCode: 1,
            stdout: '',
            stderr: 'bash: git: command not found\n',
          ),
        ),
      ),
    );
    addTearDown(container.dispose);

    final health = await serviceWith(container).check(wslEnv());

    expect(health.level, HealthLevel.failed);
    expect(health.summary, 'bash: git: command not found');
    expect(health.gitVersion, isNull);
  });

  test('a silent non-zero exit still says something useful', () async {
    environments.upsert(wslEnv());
    final container = _container(
      db,
      FakeCommandRunnerFactory(
        fallback: FakeCommandRunner(
          responder: (_) =>
              const CommandResult(exitCode: 127, stdout: '', stderr: '   '),
        ),
      ),
    );
    addTearDown(container.dispose);

    final health = await serviceWith(container).check(wslEnv());

    expect(health.level, HealthLevel.failed);
    expect(health.summary, 'Git exited with code 127.');
  });

  test(
    'an environment that cannot be reached at all is failed, not thrown',
    () async {
      environments.upsert(sshEnvFixture());
      final container = _container(
        db,
        FakeCommandRunnerFactory(
          fallback: FakeCommandRunner(
            throwError: StateError('ssh: connect to host build-box: timed out'),
          ),
        ),
      );
      addTearDown(container.dispose);

      final health = await serviceWith(container).check(sshEnvFixture());

      expect(health.level, HealthLevel.failed);
      expect(health.summary, contains('timed out'));
      // The installations it *did* know about are still reported, so the row is
      // not blank while the host is down.
      expect(health.installations, isEmpty);
    },
  );

  test('a failed environment still lists the agents recorded for it', () async {
    environments.upsert(sshEnvFixture());
    installations.insert(
      agentInstallation(environmentId: 'ssh:h1', path: '/usr/local/bin/claude'),
    );
    final container = _container(
      db,
      FakeCommandRunnerFactory(
        fallback: FakeCommandRunner(throwError: StateError('host is down')),
      ),
    );
    addTearDown(container.dispose);

    final health = await serviceWith(container).check(sshEnvFixture());

    expect(health.level, HealthLevel.failed);
    expect(health.installations, hasLength(1));
  });

  test('checkAll covers every stored environment', () async {
    environments
      ..upsert(windowsEnv())
      ..upsert(wslEnv());
    installations.insert(agentInstallation());
    final container = _container(
      db,
      FakeCommandRunnerFactory(
        byEnvironmentId: {
          'windows': FakeCommandRunner(
            responder: (_) => const CommandResult(
              exitCode: 0,
              stdout: 'git version 2.51.0',
              stderr: '',
            ),
          ),
          'wsl:Ubuntu': FakeCommandRunner(
            responder: (_) => const CommandResult(
              exitCode: 1,
              stdout: '',
              stderr: 'git: not found',
            ),
          ),
        },
      ),
    );
    addTearDown(container.dispose);

    final all = await serviceWith(container).checkAll();

    expect(all, hasLength(2));
    expect(
      {for (final h in all) h.environment.id: h.level},
      {'windows': HealthLevel.healthy, 'wsl:Ubuntu': HealthLevel.failed},
    );
  });

  test('checkAll on an empty store is an empty list, not an error', () async {
    final container = _container(db, _okFactory());
    addTearDown(container.dispose);

    expect(await serviceWith(container).checkAll(), isEmpty);
  });

  test(
    'it asks git for its version, in the environment being checked',
    () async {
      environments.upsert(wslEnv());
      final runner = FakeCommandRunner(
        responder: (_) => const CommandResult(
          exitCode: 0,
          stdout: 'git version 2.51.0',
          stderr: '',
        ),
      );
      final container = _container(
        db,
        FakeCommandRunnerFactory(byEnvironmentId: {'wsl:Ubuntu': runner}),
      );
      addTearDown(container.dispose);

      await serviceWith(container).check(wslEnv());

      expect(runner.requests.single.executable, 'git');
      expect(runner.requests.single.arguments, ['--version']);
    },
  );
}

/// A container over the seeded database whose every environment runs commands
/// through [factory].
ProviderContainer _container(
  AppDatabase db,
  FakeCommandRunnerFactory factory,
) => ProviderContainer(
  overrides: [
    databaseProvider.overrideWithValue(db),
    commandRunnerFactoryProvider.overrideWithValue(factory),
  ],
);

FakeCommandRunnerFactory _okFactory() => FakeCommandRunnerFactory(
  fallback: FakeCommandRunner(
    responder: (_) => const CommandResult(
      exitCode: 0,
      stdout: 'git version 2.51.0',
      stderr: '',
    ),
  ),
);
