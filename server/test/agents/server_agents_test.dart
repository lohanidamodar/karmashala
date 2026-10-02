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
