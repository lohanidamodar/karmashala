import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_acp/karmashala_acp.dart' show AuthMethod;
import 'package:karmashala_acp/testing.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_environments/store.dart';
import 'package:karmashala_host/src/acp/acp_arguments.dart';
import 'package:karmashala_host/src/acp/acp_auth.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

import 'acp_fixture.dart';

/// Server-side `agy acp` integration: `acpArgumentsFor` passes `['acp']`
/// without standalone `--uid=` on Linux, and `ServerAcpAuth` offers
/// `agy acp --login` only for `agy` subcommand installs (not standalone
/// `agy_acp_server`).
void main() {
  final t0 = DateTime.utc(2026, 11, 22, 12);
  final wsl = ExecutionEnvironment(
    id: 'wsl:archlinux',
    kind: EnvironmentKind.wsl,
    name: 'archlinux',
    wslDistribution: 'archlinux',
    createdAt: t0,
  );
  final agyCliAcp = AgentInstallation(
    id: 'agy-acp-cli',
    agentId: AgentIds.antigravityAcp,
    executable: const EnvironmentPath(
      environmentId: 'wsl:archlinux',
      path: '/home/u/.local/bin/agy',
    ),
    leadingArguments: const ['acp'],
    createdAt: t0,
  );
  final standaloneAcp = AgentInstallation(
    id: 'agy-acp-par',
    agentId: AgentIds.antigravityAcp,
    executable: const EnvironmentPath(
      environmentId: 'wsl:archlinux',
      path: '/home/u/acp/agy_acp_server.par',
    ),
    createdAt: t0,
  );

  test('acpArgumentsFor omits --uid= for `agy acp` and keeps it for standalone '
      'agy_acp_server.par on Linux', () {
    final spec = antigravityAcpDescriptor.acp!;
    expect(acpArgumentsFor(agyCliAcp, spec, linux: true), ['acp']);
    expect(acpArgumentsFor(agyCliAcp, spec, linux: false), ['acp']);
    expect(acpArgumentsFor(standaloneAcp, spec, linux: true), ['--uid=']);
    expect(acpArgumentsFor(standaloneAcp, spec, linux: false), isEmpty);
  });

  group('ServerAcpAuth for agy acp vs standalone agy_acp_server', () {
    late AppDatabase database;
    late List<CommandRequest> spawned;
    late List<AcpLoginTerminal> terminals;

    setUp(() {
      database = AppDatabase.memory();
      ExecutionEnvironmentDao(database).upsert(wsl);
      AgentInstallationDao(database)
        ..insert(agyCliAcp)
        ..insert(standaloneAcp);
      spawned = [];
      terminals = [];
    });

    tearDown(() => database.close());

    ServerAcpAuth auth() => ServerAcpAuth(
      installations: () => [agyCliAcp, standaloneAcp],
      environments: () => [wsl],
      registry: () => AgentRegistry.builtIn,
      choices: AcpAuthChoiceDao(database),
      spawn: (env, req) async {
        spawned.add(req);
        final agent = FakeAcpAgent(
          authMethods: const [
            AuthMethod(id: 'oauth-personal', name: 'Log in with Google'),
          ],
        );
        return FakeAcpProcess(agent).spawn();
      },
      openTerminal: (terminal) {
        terminals.add(terminal);
        return Future.value(0);
      },
      now: () => t0,
    );

    test('offers `agy acp --login` on agy subcommand installs and runs it in '
        'a terminal', () async {
      final server = auth();
      final methods = await server.methods(agyCliAcp.id);
      expect(spawned.single.arguments, ['acp']);
      expect(
        methods.methods.map((m) => m.id),
        containsAll(['oauth-personal', kAcpOwnTerminalLoginId]),
      );

      final state = await server.terminalLogin(
        agyCliAcp.id,
        kAcpOwnTerminalLoginId,
      );
      expect(terminals.single.executable, '/home/u/.local/bin/agy');
      expect(terminals.single.arguments, ['acp', '--login']);
      expect(state.methodId, kAcpOwnTerminalLoginId);
    });

    test('does not offer `agy acp --login` on standalone agy_acp_server', () async {
      final server = auth();
      final methods = await server.methods(standaloneAcp.id);
      expect(spawned.single.arguments, ['--uid=']);
      expect(
        methods.methods.map((m) => m.id),
        isNot(contains(kAcpOwnTerminalLoginId)),
      );
      await expectLater(
        server.terminalLogin(standaloneAcp.id, kAcpOwnTerminalLoginId),
        throwsA(isA<DataRefused>()),
      );
    });
  });
}
