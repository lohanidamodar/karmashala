import 'dart:io';

import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/application/agent_status_providers.dart';
import 'package:karmashala/src/features/agents/data/agent_hook_receiver.dart';
import 'package:karmashala/src/features/agents/data/agent_status_service.dart';
import 'package:karmashala/src/features/agents/domain/agent_hook_endpoint.dart';
import 'package:karmashala/src/features/agents/domain/agent_ids.dart';
import 'package:karmashala/src/features/agents/domain/agent_registry.dart';
import 'package:karmashala/src/features/agents/domain/agent_status.dart';
import 'package:karmashala/src/features/mcp/launcher_control_server.dart';
import 'package:karmashala/src/features/notifications/application/notification_providers.dart';
import 'package:karmashala/src/features/notifications/application/session_status_registry.dart';
import 'package:karmashala/src/features/notifications/domain/agent_session_key.dart';
import 'package:karmashala/src/features/notifications/domain/watched_session.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala/src/features/environments/domain/environment_kind.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// The wire between `/agent-hook` and the status registry.
///
/// `agent_hook_route_test.dart` proves the route's transport and its auth; this
/// proves the thing the route is *for*. A hook is authoritative and free, so
/// the callback must move the session's status where it lands — not five
/// seconds later, when a poll gets round to noticing that the hook store
/// changed under it.
void main() {
  const key = AgentSessionKey(AgentIds.claudeCode, 's1');

  late Directory tmp;
  late FixedClock clock;
  late AgentHookReports reports;
  late SessionStatusRegistry registry;
  late ProviderContainer container;
  late LauncherControlServer server;
  late AgentHookEndpoint endpoint;
  late List<WatchedSession> watched;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('chitra_hook_status_');
    clock = FixedClock(testTime);
    reports = AgentHookReports();
    watched = const [
      WatchedSession(
        key: key,
        label: 'Fix login',
        openId: 'row-1',
        imported: true,
      ),
    ];
    registry = SessionStatusRegistry(
      statusService: AgentStatusService(
        registry: AgentRegistry.builtIn,
        hookReports: reports,
        clock: clock,
      ),
      agents: AgentRegistry.builtIn,
      loadSessions: () => watched,
      clock: clock,
    );
    container = ProviderContainer(
      overrides: [
        clockProvider.overrideWithValue(clock),
        agentHookReportsProvider.overrideWithValue(reports),
        sessionStatusRegistryProvider.overrideWithValue(registry),
      ],
    );
    server = LauncherControlServer(container);
    await server.start(
      bridgeFilePath: p.join(tmp.path, 'mcp_bridge.json'),
      useLocalSocket: false,
    );
    endpoint = server.hookEndpoint!;
  });

  tearDown(() async {
    await server.stop();
    registry.dispose();
    container.dispose();
    tmp.deleteSync(recursive: true);
  });

  Future<void> fire(String event) async {
    final client = HttpClient();
    try {
      final request = await client.openUrl(
        'POST',
        endpoint.uriFor(
          agentId: AgentIds.claudeCode,
          event: event,
          environment: EnvironmentKind.windowsNative,
        )!,
      );
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${endpoint.token}',
      );
      request.write('{"session_id":"s1"}');
      await (await request.close()).drain<void>();
    } finally {
      client.close();
    }
  }

  test('a callback moves the session status where it lands', () async {
    await registry.cycle();
    final cycles = registry.cycles;

    await fire('Notification');

    expect(
      registry.reportForKey(key)?.status,
      AgentActivityStatus.awaitingApproval,
    );
    expect(registry.hookReports, 1);
    expect(registry.hookFastUpdates, 1);
    expect(registry.cycles, cycles, reason: 'and cost no cycle to do it');
  });

  test('an unrecognised event is still a 200 and changes nothing', () async {
    await registry.cycle();
    await fire('SomethingElse');

    expect(registry.reportForKey(key)?.status, AgentActivityStatus.unknown);
    expect(registry.hookFastUpdates, 0);
  });
}
