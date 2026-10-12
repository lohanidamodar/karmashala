import 'package:agent_cli/descriptors.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/agents/application/agent_model_catalog_providers.dart';
import 'package:karmashala/src/features/agents/application/agent_providers.dart';

import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';

/// The picker offers what the server read from the agent's own CLI, merged
/// with the curated list, and the curated list until a list was read.
void main() {
  const wsl = (agentId: AgentIds.antigravity, environmentId: 'wsl:Ubuntu');

  late FakeDataServer server;

  Future<ProviderContainer> container() async {
    final db = TestMachine();
    server = FakeDataServer()..runsOn(db);
    server.environmentRows
      ..upsert(windowsEnv())
      ..upsert(wslEnv());
    server.installationRows.insert(
      agentInstallation(
        id: 'agy-wsl',
        agentId: AgentIds.antigravity,
        environmentId: 'wsl:Ubuntu',
        path: '/home/me/.local/bin/agy',
      ),
    );
    final c = ProviderContainer(overrides: [await server.override()]);
    addTearDown(c.dispose);
    return c;
  }

  List<AgentModel> curated(ProviderContainer c) => c
      .read(agentRegistryProvider)
      .byId(AgentIds.antigravity)!
      .launch
      .model
      .models;

  test('the WSL installation\'s list is asked for by its own id, and a new '
      'model appears beside the curated labels', () async {
    final c = await container();
    server.agentWork.modelCatalogs['agy-wsl'] = AgentModelCatalog(
      installationId: 'agy-wsl',
      models: const [
        AgentModel(id: 'argon-4', label: 'argon-4', summary: ''),
        AgentModel(
          id: 'gemini-3.8-flash-high',
          label: 'gemini-3.8-flash-high',
          summary: '',
        ),
      ],
      readAt: testTime,
      source: 'agy models',
    );

    final catalog = await c.read(discoveredModelsInProvider(wsl).future);
    expect(catalog!.source, 'agy models');
    expect(server.agentWork.modelReads, [('agy-wsl', false)]);

    final support = c.read(agentModelSupportInProvider(wsl));
    expect(support.listedLive, isTrue);
    expect(support.models.map((m) => m.id), [
      'argon-4',
      'gemini-3.8-flash-high',
    ]);
    expect(support.models.first.label, 'Argon 4');
    // The agent gave a bare id; the curated entry names it.
    expect(support.models.last.label, 'Gemini 3.8 Flash (High)');
  });

  test('a refresh asks the server to read the agent now, then re-reads the '
      'cache', () async {
    final c = await container();
    expect(await c.read(discoveredModelsInProvider(wsl).future), isNotNull);
    server.agentWork.modelCatalogs['agy-wsl'] = AgentModelCatalog(
      installationId: 'agy-wsl',
      models: const [AgentModel(id: 'argon-4', label: '', summary: '')],
      readAt: testTime,
      source: 'agy models',
    );

    final read = await c.read(agentModelsRefreshProvider)(wsl);
    expect(read!.models.single.id, 'argon-4');
    await c.read(discoveredModelsInProvider(wsl).future);
    expect(server.agentWork.modelReads, [
      ('agy-wsl', false),
      ('agy-wsl', true),
      ('agy-wsl', false),
    ]);
    expect(
      c.read(agentModelSupportInProvider(wsl)).models.single.label,
      'Argon 4',
    );
  });

  test('with nothing read the curated list stands', () async {
    final c = await container();
    final catalog = await c.read(discoveredModelsInProvider(wsl).future);
    expect(catalog!.isLive, isFalse);
    final support = c.read(agentModelSupportInProvider(wsl));
    expect(support.models, curated(c));
    expect(support.listedLive, isFalse);
  });

  test('an environment with no installation asks nothing', () async {
    final c = await container();
    const host = (agentId: AgentIds.antigravity, environmentId: 'windows');
    expect(await c.read(discoveredModelsInProvider(host).future), isNull);
    expect(server.agentWork.modelReads, isEmpty);
    expect(c.read(agentModelSupportInProvider(host)).models, curated(c));
  });
}
