import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/process/command_runner.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/agents/domain/agent_ids.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/environments/presentation/environments_section.dart';
import 'package:karmashala/src/features/environments/domain/environment_path.dart';
import 'package:karmashala/src/features/ssh/data/ssh_host_dao.dart';
import 'package:karmashala/src/features/ssh/domain/ssh_host.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

void main() {
  late AppDatabase db;
  late ExecutionEnvironmentDao environments;
  late AgentInstallationDao installations;
  late SshHostDao hosts;
  late FakeCommandRunnerFactory runners;

  SshHost remoteHost({String keyPath = r'C:\keys\missing_id_ed25519'}) =>
      SshHost(
        id: 'h1',
        name: 'build-box',
        host: '127.0.0.1',
        port: 2222,
        username: 'dev',
        authMethod: SshAuthMethod.privateKey,
        privateKey: EnvironmentPath(environmentId: 'windows', path: keyPath),
        createdAt: testTime,
      );

  setUp(() {
    db = AppDatabase.memory();
    environments = ExecutionEnvironmentDao(db);
    installations = AgentInstallationDao(db);
    hosts = SshHostDao(db);
    runners = FakeCommandRunnerFactory();
    environments.upsert(windowsEnv());
  });
  tearDown(() => db.close());

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          clockProvider.overrideWithValue(FixedClock(testTime)),
          idGeneratorProvider.overrideWithValue(SequentialIdGenerator()),
          commandRunnerFactoryProvider.overrideWithValue(runners),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: EnvironmentsSection()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('agents are listed under the environment they live in', (
    tester,
  ) async {
    environments.upsert(wslEnv(id: 'wsl:Ubuntu', distro: 'Ubuntu'));
    environments.upsert(sshEnvFixture());
    hosts.upsert(remoteHost());
    installations.insert(agentInstallation());
    installations.insert(
      agentInstallation(
        id: 'a2',
        environmentId: 'ssh:h1',
        path: '/home/dev/.local/bin/claude',
        version: '2.1.251',
      ),
    );
    installations.insert(
      agentInstallation(
        id: 'a3',
        agentId: AgentIds.codex,
        environmentId: 'ssh:h1',
        path: '/home/dev/.local/bin/codex',
        version: '0.146.0',
      ),
    );

    await pump(tester);

    expect(find.text('WINDOWS'), findsOneWidget);
    expect(find.text('WSL'), findsOneWidget);
    expect(find.text('SSH'), findsOneWidget);
    // The remote host reads as a machine, not as an opaque id.
    expect(find.text('ssh:h1 · dev@127.0.0.1:2222'), findsOneWidget);
    // Same agent, two environments, two independent installations — with the
    // remote versions and paths visible beside the local one.
    expect(find.text('v2.1.251 · /home/dev/.local/bin/claude'), findsOneWidget);
    expect(find.text('v0.146.0 · /home/dev/.local/bin/codex'), findsOneWidget);
    expect(find.text(r'v1.0.0 · C:\Users\me\.bin\claude.exe'), findsOneWidget);
  });

  testWidgets('an SSH environment shows its connection state', (tester) async {
    environments.upsert(sshEnvFixture());
    hosts.upsert(remoteHost());
    await pump(tester);
    // Nothing has dialled, and the card says exactly that rather than nothing.
    expect(find.text('Not connected'), findsOneWidget);
    expect(find.text('Connect and find agents'), findsOneWidget);
  });

  testWidgets('a remote scan that cannot connect says so, loudly', (
    tester,
  ) async {
    // The trap this guards: agent discovery treats an unreachable environment
    // as "nothing installed", so without an explicit connect a refused host
    // would render as a perfectly ordinary empty result.
    environments.upsert(sshEnvFixture());
    hosts.upsert(remoteHost());
    await pump(tester);

    await tester.tap(find.text('Connect and find agents'));
    await tester.pump();
    // The key check is real filesystem work, which only runs outside the
    // test's fake clock.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pumpAndSettle();

    // Both the chip and the scan report it — the state and the action agree.
    expect(find.text('Failed'), findsOneWidget);
    expect(find.textContaining('Private key not found'), findsWidgets);
    expect(find.textContaining('No agents found here'), findsNothing);
  });

  testWidgets('a local scan records what it finds', (tester) async {
    runners = FakeCommandRunnerFactory(
      fallback: FakeCommandRunner(
        responder: (request) => switch (request.executable) {
          'where' => const CommandResult(
            exitCode: 0,
            stdout: r'C:\bin\claude.exe',
            stderr: '',
          ),
          _ => const CommandResult(exitCode: 0, stdout: '9.9.9', stderr: ''),
        },
      ),
    );
    await pump(tester);

    await tester.tap(find.text('Find agents'));
    await tester.pumpAndSettle();

    expect(installations.getByEnvironment('windows'), isNotEmpty);
    expect(find.textContaining(r'v9.9.9 · C:\bin\claude.exe'), findsWidgets);
  });
}
