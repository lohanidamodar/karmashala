import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/data.dart';
import 'package:karmashala_host/src/agents/agent_registry_holder.dart';
import 'package:karmashala_host/src/agents/server_agents.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

import 'agent_work_support.dart';

/// The server's probe of its own machine: a leftover row of an agent the
/// registry no longer knows goes with the next refresh. Every command is
/// answered by a script; nothing is spawned.
void main() {
  final now = DateTime.utc(2026, 10, 2, 12);
  late AppDatabase db;
  late DataService service;
  late List<DataChanges> told;

  setUp(() {
    db = AppDatabase.memory();
    service = DataService(db, clock: () => now);
    told = [];
    service.open(told.add).handle(const DataSubscribe());
  });
  tearDown(() => db.close());

  test('a refresh reads an ACP agent\'s version over the protocol', () async {
    final row = AcpAgentRow(
      id: 'r1',
      name: 'Mine',
      command: 'mine',
      createdAt: now,
    );
    const minePath = r'C:\bin\mine.exe';
    final asked = <String>[];
    final agents = ServerAgents(
      data: service,
      registryHolder: AgentRegistryHolder(
        AgentRegistry.withExtra([acpAgentAdapter(row)]),
      ),
      // Located whichever shell this machine asks with.
      runner: ScriptedRunner(
        (request) => request.arguments.any((a) => a.contains('mine'))
            ? const CommandResult(
                exitCode: 0,
                stdout: '$minePath\n',
                stderr: '',
              )
            : notFound,
      ),
      clock: MutableClock(now),
      ids: CountingIds(),
      hostEnvironment: const {},
      acpVersion: (installation, descriptor, environment) async {
        asked.add('${descriptor.id}:${installation.executable.path}');
        return '1.0.91';
      },
    );

    final scan = await agents.refresh();

    expect(scan.error, isNull);
    expect(asked, ['${row.agentId}:$minePath']);
    final mine = scan.agents.single.installation;
    expect(mine.agentId, row.agentId);
    expect(mine.version, '1.0.91');
    expect(mine.versionReadAt, now);
    expect(
      told
          .expand((batch) => batch.changes)
          .whereType<InstallationChanged>()
          .map((c) => c.installation.version),
      contains('1.0.91'),
    );
  });

  test(
    'a refresh probes an ACP agent added since the server started',
    () async {
      const minePath = r'C:\bin\mine.exe';
      final holder = AgentRegistryHolder.composed(service.acpAgents)
        ..follow(service);
      final agents = ServerAgents(
        data: service,
        registryHolder: holder,
        runner: ScriptedRunner(
          (request) => request.arguments.any((a) => a.contains('mine'))
              ? const CommandResult(
                  exitCode: 0,
                  stdout: '$minePath\n',
                  stderr: '',
                )
              : notFound,
        ),
        clock: MutableClock(now),
        ids: CountingIds(),
        hostEnvironment: const {},
      );
      expect((await agents.refresh()).agents, isEmpty);

      service
          .open((_) {})
          .handle(
            const AcpAgentPut(id: 'r1', agentName: 'Mine', command: 'mine'),
          );

      final scan = await agents.refresh();
      expect(scan.agents.single.installation.agentId, 'acp:r1');
      expect(scan.agents.single.installation.executable.path, minePath);
    },
  );

  test(
    'a refresh drops the row of an agent the registry has forgotten',
    () async {
      final holder = AgentRegistryHolder.composed(service.acpAgents)
        ..follow(service);
      final agents = ServerAgents(
        data: service,
        registryHolder: holder,
        runner: ScriptedRunner((_) => notFound),
        clock: MutableClock(now),
        ids: CountingIds(),
        // No declared install paths expand, so nothing is "found" at one.
        hostEnvironment: const {},
      );
      final here = agents.environment;
      service.recordAgentsFound(here, [
        AgentInstallation(
          id: 'ghost',
          agentId: 'acp:gone',
          executable: EnvironmentPath(
            environmentId: here.id,
            path: r'C:\gone\agent.exe',
          ),
          createdAt: now,
        ),
      ], now);
      expect(service.installationsIn(here.id).single.agentId, 'acp:gone');
      told.clear();

      final scan = await agents.refresh();

      expect(scan.error, isNull);
      expect(service.installationsIn(here.id), isEmpty);
      expect(
        told
            .expand((batch) => batch.changes)
            .whereType<InstallationRemoved>()
            .single
            .id,
        'ghost',
      );
    },
  );
}
