import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_agent_reporting/hooks.dart';
import 'package:karmashala_agent_reporting/status.dart';
import 'package:karmashala_agent_status/karmashala_agent_status.dart';
import 'package:karmashala_core/util.dart';
import 'package:karmashala_host/src/attention/server_session_status.dart';
import 'package:karmashala_notifications/watched.dart';
import 'package:test/test.dart';

class _Clock implements Clock {
  _Clock(this.now);
  DateTime now;
  @override
  DateTime nowUtc() => now.toUtc();
}

/// When a turn began, on every working status the server sends: the agent's
/// own working line when its screen shows one, else the first reading of the
/// turn as working — never left out, so a working line can always count.
void main() {
  final start = DateTime.utc(2026, 10, 7, 9);
  late _Clock clock;
  late AgentHookReports reports;
  late AgentHookReceiver receiver;
  late List<WatchedSession> watched;

  setUp(() {
    clock = _Clock(start);
    reports = AgentHookReports();
    receiver = AgentHookReceiver(
      registry: AgentRegistry.builtIn,
      reports: reports,
      clock: clock,
    );
    watched = [];
  });

  ServerSessionStatus build({HostedStatusKeeper? keeper}) =>
      ServerSessionStatus(
        statusService: AgentStatusService(
          registry: AgentRegistry.builtIn,
          hookReports: reports,
          clock: clock,
        ),
        agents: AgentRegistry.builtIn,
        loadSessions: () => watched,
        clock: clock,
        heldByHost: keeper == null
            ? null
            : (session) => session.openId == 'row-1',
        hostStatusFor: keeper == null
            ? null
            : (session) => keeper.statusOf(session.openId),
      );

  void hook(String event) => receiver.handle(
    agentId: AgentIds.claudeCode,
    event: event,
    body: '{"session_id":"conv-1"}',
  );

  test(
    'with no line to read, the turn counts from its first reading',
    () async {
      watched.add(
        const WatchedSession(
          key: AgentSessionKey(AgentIds.claudeCode, 'conv-1'),
          label: 'Hooked',
          openId: 'row-1',
          imported: false,
        ),
      );
      final status = build();
      hook('UserPromptSubmit');
      await status.cycle();
      final first = status.reportForOpenId('row-1')!;
      expect(first.status, AgentActivityStatus.working);
      expect(first.working?.since, start);

      clock.now = start.add(const Duration(seconds: 30));
      hook('PreToolUse');
      await status.cycle();
      expect(
        status.reportForOpenId('row-1')!.working?.since,
        start,
        reason: 'a later hook in the same turn is not a new turn',
      );

      hook('Stop');
      await status.cycle();
      expect(status.reportForOpenId('row-1')!.working, isNull);

      clock.now = start.add(const Duration(minutes: 2));
      hook('UserPromptSubmit');
      await status.cycle();
      expect(
        status.reportForOpenId('row-1')!.working?.since,
        start.add(const Duration(minutes: 2)),
      );
      await status.close();
    },
  );

  test('a session the server runs carries its screen\'s line', () async {
    final keeper = HostedStatusKeeper(
      agents: AgentRegistry.builtIn,
      clock: clock,
    )..track('row-1', agentId: AgentIds.codex, conversationId: 'conv-1');
    watched.add(
      const WatchedSession(
        key: AgentSessionKey(AgentIds.codex, 'conv-1'),
        label: 'Hosted',
        openId: 'row-1',
        imported: false,
      ),
    );
    final status = build(keeper: keeper);
    keeper.screen('row-1', const [
      '› Fix the build',
      '',
      '• Working (6s • esc to interrupt)',
      '',
      '› Ask Codex to do anything',
    ]);
    await status.cycle();

    final report = status.reportForOpenId('row-1')!;
    expect(report.status, AgentActivityStatus.working);
    expect(report.working?.word, 'Working');
    expect(report.working?.since, start.subtract(const Duration(seconds: 6)));
    await status.close();
  });
}
