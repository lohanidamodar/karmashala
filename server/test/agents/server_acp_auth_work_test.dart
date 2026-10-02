import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_acp/karmashala_acp.dart' show AuthMethod;
import 'package:karmashala_acp/testing.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_environments/store.dart';
import 'package:karmashala_host/data.dart';
import 'package:karmashala_host/src/acp/acp_auth.dart';
import 'package:karmashala_host/src/agents/server_agent_work.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

import '../acp/acp_fixture.dart';

/// The `acpAuth.*` requests, as a client asks them on the data channel:
/// answered by the server's ACP login work, and refused `unavailable` by a
/// server that has none.
void main() {
  final t0 = DateTime.utc(2026, 10, 2, 12);
  final wsl = ExecutionEnvironment(
    id: 'wsl:Ubuntu',
    kind: EnvironmentKind.wsl,
    name: 'Ubuntu',
    wslDistribution: 'Ubuntu',
    createdAt: t0,
  );
  final installation = AgentInstallation(
    id: 'ag1',
    agentId: 'antigravity-acp',
    executable: const EnvironmentPath(
      environmentId: 'wsl:Ubuntu',
      path: '/home/me/agy_acp_server.par',
    ),
    createdAt: t0,
  );

  late AppDatabase db;
  late DataService service;
  late DataSession app;
  late FakeAcpAgent agent;

  ServerAgentWork work({ServerAcpAuth? acpAuth}) =>
      ServerAgentWork(data: service, acpAuth: acpAuth, onItsOwn: false)
        ..attach();

  setUp(() {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(wsl);
    AgentInstallationDao(db).insert(installation);
    service = DataService(db, clock: () => t0);
    app = service.open((_) {});
    agent = FakeAcpAgent(
      authMethods: const [AuthMethod(id: 'oauth', name: 'Log in')],
    );
  });
  tearDown(() => db.close());

  test(
    'methods, authenticate, state and forget answer on the channel',
    () async {
      final server = work(
        acpAuth: ServerAcpAuth(
          installations: () => [installation],
          environments: () => [wsl],
          registry: () => AgentRegistry.builtIn,
          choices: AcpAuthChoiceDao(db),
          spawn: (_, _) => FakeAcpProcess(agent).spawn(),
          now: () => t0,
        ),
      );
      addTearDown(server.stop);

      final methods = (await app.handleLater(
        const AcpAuthMethodsRead('ag1'),
      )).value;
      expect(methods.methods.single.name, 'Log in');

      agent = FakeAcpAgent(
        authMethods: const [AuthMethod(id: 'oauth', name: 'Log in')],
      );
      final state = (await app.handleLater(
        const AcpAuthenticate(installationId: 'ag1', methodId: 'oauth'),
      )).value;
      expect(state.confirmed, isTrue);
      expect(
        (await app.handleLater(const AcpAuthStateRead('ag1'))).value!.methodId,
        'oauth',
      );

      await app.handleLater(const AcpAuthClear('ag1'));
      expect(
        (await app.handleLater(const AcpAuthStateRead('ag1'))).value,
        isNull,
      );
    },
  );

  test('a server without ACP login work refuses it unavailable', () async {
    final server = work();
    addTearDown(server.stop);
    await expectLater(
      app.handleLater(const AcpAuthStateRead('ag1')),
      throwsA(
        isA<DataRefused>().having(
          (r) => r.code,
          'code',
          DataRefusalCode.unavailable,
        ),
      ),
    );
  });
}
