import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import 'package:agent_cli/usage.dart';
import 'package:karmashala_host/data.dart';
import 'package:karmashala_host/src/agents/server_agent_work.dart';
import 'package:karmashala_host/src/mcp/tools/usage_tool_set.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

import '../../agents/agent_work_support.dart';

/// `get_usage`, answered by the server from its own usage reading (slice
/// 2a) — through the one throttled service, never forwarded to the app.
void main() {
  final start = DateTime.utc(2026, 9, 27, 12);
  late MutableClock clock;
  late AppDatabase db;
  late DataService data;
  late ScriptedUsageService vendor;
  late ServerAgentWork work;
  late UsageToolSet tools;

  setUp(() {
    clock = MutableClock(start);
    db = AppDatabase.memory();
    data = DataService(db, clock: () => clock.now)
      ..ensureEnvironment(localHostEnvironment(start));
    data.reconcileProbe(
      environmentId: localHostEnvironmentId,
      readAt: start,
      found: [
        for (final agentId in [AgentIds.claudeCode, AgentIds.antigravity])
          AgentInstallation(
            id: agentId,
            agentId: agentId,
            executable: EnvironmentPath(
              environmentId: localHostEnvironmentId,
              path: '/usr/local/bin/$agentId',
            ),
            createdAt: start,
          ),
      ],
      probed: const {},
      readings: const {},
    );
    vendor = ScriptedUsageService(
      clock: clock,
      answer: (installation) => AgentUsage(
        fetchedAt: clock.nowUtc(),
        windows: [
          if (installation.agentId == AgentIds.claudeCode)
            UsageWindow(
              label: '5-hour',
              percent: 30,
              span: kUsageFiveHourWindow,
              resetsAt: start.add(const Duration(hours: 2)),
            )
          else
            const UsageWindow(label: 'Gemini Code Assist'),
        ],
      ),
    );
    work = ServerAgentWork(
      data: data,
      clock: clock,
      ids: CountingIds(),
      usageService: (_) => vendor,
      onItsOwn: false,
    )..attach();
    tools = UsageToolSet(work.usage);
  });
  tearDown(() {
    work.stop();
    db.close();
  });

  Future<Object?> call(Map<String, dynamic> arguments) =>
      tools.call('get_usage', arguments, 's1')!;

  test('answers the account from the server\'s reading', () async {
    final answer = await call({'cli': 'claude'}) as Map<String, Object?>;
    expect(answer['environmentId'], localHostEnvironmentId);
    final window = (answer['windows']! as List).single as Map;
    expect(window['label'], '5-hour');
    expect(window['percent'], 30);
    expect(window['resetsAt'], isNotNull);
    expect(answer['fetchedAt'], start.toIso8601String());
    expect(vendor.asked, hasLength(1));

    // Inside the floor a second call is the same reading, no request.
    await call({'cli': 'claude'});
    expect(vendor.asked, hasLength(1));
  });

  test('a window nothing measured has no percent', () async {
    final answer = await call({'cli': 'antigravity'}) as Map<String, Object?>;
    final window = (answer['windows']! as List).single as Map;
    expect(window.containsKey('percent'), isFalse);
  });

  test('the server\'s failure is the agent\'s error, in its words', () async {
    vendor.answer = (_) => throw UsageException(
      'Sign in again: the token was refused.',
      kind: UsageFailureKind.auth,
    );
    await expectLater(
      call({'cli': 'claude'}),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('Sign in again'),
        ),
      ),
    );
  });

  test('an agent or environment with no installation is refused', () async {
    await expectLater(call({'cli': 'codex'}), throwsA(isA<StateError>()));
    await expectLater(
      call({'cli': 'claude', 'environmentId': 'wsl:Nope'}),
      throwsA(isA<StateError>()),
    );
  });

  test('serves get_usage and nothing else', () {
    expect([for (final s in tools.schemas) s['name']], ['get_usage']);
  });
}
