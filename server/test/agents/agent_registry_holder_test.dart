import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/data.dart';
import 'package:karmashala_host/src/agents/agent_registry_holder.dart';
import 'package:karmashala_host/src/agents/server_agents.dart';
import 'package:karmashala_host/src/mcp/tools/server_tool_context.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

/// The server's registry follows the ACP agent rows: composed at start, and
/// again after every put or delete, where the readers that hold it look.
void main() {
  late AppDatabase db;
  late DataService service;
  late DataSession app;

  setUp(() {
    db = AppDatabase.memory();
    service = DataService(db, newId: () => 'row-1');
    app = service.open((_) {});
  });
  tearDown(() => db.close());

  List<String> idsOf(AgentRegistry registry) => [
    for (final adapter in registry.adapters) adapter.id,
  ];

  test('starts from the rows the store holds', () {
    app.handle(
      const AcpAgentPut(id: 'r0', agentName: 'Early', command: 'early'),
    );
    final holder = AgentRegistryHolder.composed(service.acpAgents);
    expect(idsOf(holder.current), [...idsOf(AgentRegistry.builtIn), 'acp:r0']);
    expect(holder.current.displayNameFor('acp:r0'), 'Early');
    expect(holder.current.adapterFor('acp:r0')!.acp, isNotNull);
  });

  test('recomposes after a put and after a delete, nothing else', () {
    final holder = AgentRegistryHolder.composed(service.acpAgents)
      ..follow(service);
    expect(idsOf(holder.current), idsOf(AgentRegistry.builtIn));
    final before = holder.current;

    app.handle(const TodoAdd(id: 't', body: 'unrelated'));
    expect(holder.current, same(before));

    app.handle(
      const AcpAgentPut(agentName: 'Mine', command: 'mine', args: ['--acp']),
    );
    expect(idsOf(holder.current), contains('acp:row-1'));
    expect(holder.current.adapterFor('acp:row-1')!.acp!.arguments, ['--acp']);

    app.handle(
      const AcpAgentPut(id: 'row-1', agentName: 'Renamed', command: 'mine'),
    );
    expect(holder.current.displayNameFor('acp:row-1'), 'Renamed');

    app.handle(const AcpAgentDelete('row-1'));
    expect(idsOf(holder.current), idsOf(AgentRegistry.builtIn));
  });

  test('ServerAgents and the tool context read the holder each time', () {
    final holder = AgentRegistryHolder.composed(service.acpAgents)
      ..follow(service);
    final agents = ServerAgents(data: service, registryHolder: holder);
    final tools = ServerToolContext(
      database: db,
      data: service,
      dataDirectory: 'unused',
      registry: holder,
    );
    addTearDown(tools.close);
    expect(agents.registry.adapterFor('acp:row-1'), isNull);
    expect(tools.agents.adapterFor('acp:row-1'), isNull);

    app.handle(const AcpAgentPut(agentName: 'Mine', command: 'mine'));
    expect(agents.registry.displayNameFor('acp:row-1'), 'Mine');
    expect(tools.agents.displayNameFor('acp:row-1'), 'Mine');
  });

  test('without a holder both keep the registry they were given', () {
    const custom = AgentRegistry([]);
    expect(
      ServerAgents(data: service, registry: custom).registry,
      same(custom),
    );
    final tools = ServerToolContext(
      database: db,
      data: service,
      dataDirectory: 'unused',
      agents: custom,
    );
    addTearDown(tools.close);
    expect(tools.agents, same(custom));
  });
}
