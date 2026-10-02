import 'package:agent_cli/descriptors.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/data/data_providers.dart';
import 'package:karmashala/src/features/agents/application/agent_providers.dart';
import 'package:karmashala/src/features/agents/data/acp_agents_data.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

import '../../support/fake_data_server.dart';

/// This app's copy of the person-added ACP agents: primed from the server,
/// moved by its changes and by this app's own writes, and read into the
/// registry the app shows.
void main() {
  final t0 = DateTime.utc(2026, 10, 2, 9);
  late FakeDataServer server;

  AcpAgentRow row({
    String id = 'r1',
    String name = 'Mine',
    DateTime? createdAt,
  }) => AcpAgentRow(
    id: id,
    name: name,
    command: 'mine',
    args: const ['--acp'],
    createdAt: createdAt ?? t0,
  );

  setUp(() => server = FakeDataServer(projects: {}));

  test('primed with the rows the server holds, oldest first', () async {
    server.acpAgentRows
      ..insert(row(id: 'b', createdAt: t0.add(const Duration(minutes: 1))))
      ..insert(row(id: 'a'));
    final data = AcpAgentsData(await server.connect());
    expect(data.isPrimed, isTrue);
    expect(data.getAll().map((r) => r.id), ['a', 'b']);
    expect(data.getById('a'), row(id: 'a'));
  });

  test('a change the server makes moves the copy and fires changes', () async {
    final client = await server.connect();
    final data = AcpAgentsData(client);
    var fired = 0;
    data.changes.listen((_) => fired++);
    expect(data.getAll(), isEmpty);

    server.acpAgentRows.insert(row());
    expect(data.getAll(), [row()]);
    server.acpAgentRows.upsert(row(name: 'Renamed'));
    expect(data.getById('r1')!.name, 'Renamed');
    server.acpAgentRows.delete('r1');
    expect(data.getAll(), isEmpty);
    expect(fired, 3);
  });

  test(
    'put creates through the server and the copy holds the answer',
    () async {
      final data = AcpAgentsData(await server.connect());
      final created = await data.put(
        name: ' My Agent ',
        command: 'my-agent',
        args: const ['--acp'],
        env: const {'A': '1'},
        source: AcpAgentSource.registry,
        registryId: 'my-agent',
      );
      expect(created.name, 'My Agent');
      expect(created.source, AcpAgentSource.registry);
      expect(data.getAll(), [created]);

      final renamed = await data.put(
        id: created.id,
        name: 'Renamed',
        command: 'my-agent',
      );
      expect(renamed.id, created.id);
      expect(data.getAll().single.name, 'Renamed');

      await data.delete(created.id);
      expect(data.getAll(), isEmpty);
    },
  );

  test('a blank name is refused and nothing is kept', () async {
    final data = AcpAgentsData(await server.connect());
    await expectLater(
      data.put(name: ' ', command: 'c'),
      throwsA(
        isA<DataRefused>().having(
          (r) => r.code,
          'code',
          DataRefusalCode.invalid,
        ),
      ),
    );
    expect(data.getAll(), isEmpty);
  });

  test(
    'the registry provider shows the rows as agents, and follows them',
    () async {
      server.acpAgentRows.insert(row());
      final client = await server.connect();
      final container = ProviderContainer(
        overrides: [dataClientProvider.overrideWithValue(client)],
      );
      addTearDown(container.dispose);

      var registry = container.read(agentRegistryProvider);
      expect(
        registry.adapters.length,
        AgentRegistry.builtIn.adapters.length + 1,
      );
      final adapter = registry.adapterFor(row().agentId)!;
      expect(adapter.descriptor.displayName, 'Mine');
      expect(adapter.acp, isNotNull);
      expect(adapter.acp!.arguments, ['--acp']);

      server.acpAgentRows.delete('r1');
      registry = container.read(agentRegistryProvider);
      expect(registry.adapters.length, AgentRegistry.builtIn.adapters.length);
    },
  );
}
