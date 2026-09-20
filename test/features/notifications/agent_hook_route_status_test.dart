import 'dart:io';

import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/application/agent_status_providers.dart';
import 'package:karmashala_agent_reporting/hooks.dart';
import 'package:karmashala_agent_reporting/status.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/mcp/launcher_control_server.dart';
import 'package:karmashala/src/features/notifications/application/notification_providers.dart';
import 'package:karmashala/src/features/notifications/application/session_status_registry.dart';
import 'package:karmashala_notifications/watched.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:agent_cli/process.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/temp_directory.dart';

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
    tmp = Directory.systemTemp.createTempSync('karmashala_hook_status_');
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
    removeTempDirectory(tmp);
  });

  Future<void> fire(String event, {String body = '{"session_id":"s1"}'}) async {
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
      request.write(body);
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

  test('a turn paused on a subagent does not reach the registry as a finished '
      'one', () async {
    // The whole path, not just the classifier: Claude Code fires a real `Stop`
    // on the main thread the moment a `Task` worker is launched, and this is
    // where that used to become "Agent finished". The two bodies are the two
    // `Stop` payloads captured from one 13-second turn on 2026-09-04; they
    // differ in `background_tasks` and in nothing else that matters.
    await registry.cycle();
    await fire('PreToolUse');
    expect(registry.reportForKey(key)?.status, AgentActivityStatus.working);

    await fire(
      'Stop',
      body:
          '{"session_id":"s1","hook_event_name":"Stop",'
          '"last_assistant_message":"Agent launched to run the command'
          '\\u2014waiting for completion.",'
          '"background_tasks":[{"id":"a8989a29ed73d4888","type":"subagent",'
          '"status":"running","description":"Run echo subagent-ran"}]}',
    );
    expect(registry.reportForKey(key)?.status, AgentActivityStatus.working);

    await fire(
      'Stop',
      body:
          '{"session_id":"s1","hook_event_name":"Stop",'
          '"last_assistant_message":"The subagent executed the command '
          'successfully.","background_tasks":[]}',
    );
    final report = registry.reportForKey(key)!;
    expect(report.status, AgentActivityStatus.idle);
    // And the completion arrives able to say what it completed.
    expect(report.evidence, [
      'The subagent executed the command successfully.',
    ]);
  });

  test('an unrecognised event is still a 200 and changes nothing', () async {
    await registry.cycle();
    await fire('SomethingElse');

    expect(registry.reportForKey(key)?.status, AgentActivityStatus.unknown);
    expect(registry.hookFastUpdates, 0);
  });
}
