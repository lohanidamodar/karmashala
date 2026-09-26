import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/mcp/mcp_tool_dispatcher.dart';
import 'package:karmashala/src/features/sessions/application/host_lifecycle/host_lifecycle_providers.dart';
import 'package:karmashala_store/database.dart';

import '../../support/fake_host_lifecycle.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/fake_data_server.dart';
import '../../support/workspace_mirror.dart';
import '../terminal/fake_instance.dart';
import 'package:karmashala/src/features/sessions/application/session_providers.dart';

Future<void> _settle() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// The session host serves agents' MCP and forwards each call over the
/// lifecycle link; the app runs it with the caller the host's token named.
void main() {
  late AppDatabase db;
  late FakeSessionRows dao;
  late FakeHostLifecycle host;
  late ProviderContainer container;

  setUp(() async {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    final fake = FakeDataServer()..mirrorInto(db);
    fake.projectRows.insert(project());
    fake.repositoryRows.insert(repository());
    AgentInstallationDao(db).insert(agentInstallation());
    dao = fake.sessionRows
      ..insert(session(id: 's1', title: 'Work'))
      ..insert(session(id: 's2', title: 'Other'));
    host = FakeHostLifecycle();
    container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        await fake.override(),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        hostLifecycleSourceProvider.overrideWithValue(host),
      ],
    );
    addTearDown(() {
      container.dispose();
      db.close();
    });
    container.listen(hostLifecycleSubscriberProvider, (_, _) {});
    await _settle();
  });

  test('each link offers the host the whole served catalogue', () {
    expect(host.offeredTools, hasLength(1));
    final names = [for (final tool in host.offeredTools.single) tool['name']];
    expect(names, [
      for (final tool in McpToolDispatcher.servedCatalogue()) tool['name'],
    ]);
  });

  test('a forwarded call runs as the session the host authenticated, not as '
      'anything its arguments claim', () async {
    host.mcpCallLink.add((
      callId: 4,
      tool: 'session_rename',
      arguments: {'title': 'Renamed by its own agent', 'callerSessionId': 's2'},
      callerSessionId: 's1',
    ));
    await _settle();

    final answer = host.mcpAnswers.single;
    expect(answer.callId, 4);
    expect(answer.error, isNull);
    expect((answer.result! as Map)['sessionId'], 's1');
    await container.read(sessionsDataProvider).settled();
    expect(dao.getById('s1')!.title, 'Renamed by its own agent');
    expect(dao.getById('s2')!.title, 'Other');
  });

  test('a failing tool is answered with the text the agent reads', () async {
    host.mcpCallLink.add((
      callId: 5,
      tool: 'session_rename',
      arguments: {'title': 'Nobody'},
      callerSessionId: null,
    ));
    host.mcpCallLink.add((
      callId: 6,
      tool: 'no_such_tool',
      arguments: const {},
      callerSessionId: 's1',
    ));
    await _settle();

    final byId = {for (final a in host.mcpAnswers) a.callId: a};
    expect(
      byId[5]!.error,
      contains(
        'this caller is not running inside a '
        'session',
      ),
    );
    expect(byId[6]!.error, contains('Unknown tool: no_such_tool'));
  });
}
