import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart' show CommandRunnerFactory;
import 'package:agent_cli/usage.dart';
import 'package:karmashala_automations/store.dart' show CheckoutRows;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/src/sessions/acp_session_stats.dart';
import 'package:karmashala_host/src/sessions/session_record_readings.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

/// `sessions.stats` for a session whose agent speaks ACP: counted from the
/// rows and the usage this server kept, never from a file the agent never
/// wrote — decided by the adapter's capability, not its id.
void main() {
  final t0 = DateTime.utc(2026, 10, 2, 12);

  SessionMessage row(
    String id,
    SessionMessageRole role, {
    String text = 'x',
    String? toolJson,
    int second = 0,
  }) => SessionMessage(
    id: id,
    sessionId: 's1',
    role: role,
    text: text,
    toolJson: toolJson,
    createdAt: t0.add(Duration(seconds: second)),
    updatedAt: t0.add(Duration(seconds: second)),
  );

  group('acpSessionStats', () {
    test('counts turns, replies and tool calls by name off the rows', () {
      final stats = acpSessionStats(
        rows: [
          row('m1', SessionMessageRole.user),
          row('m2', SessionMessageRole.agent, text: ''),
          row('m3', SessionMessageRole.agent),
          row(
            'm4',
            SessionMessageRole.tool,
            toolJson: '{"toolCallId":"t1","name":"Read","title":"Read a file"}',
          ),
          row(
            'm5',
            SessionMessageRole.tool,
            toolJson: '{"toolCallId":"t2","title":"Read a file"}',
          ),
          row('m6', SessionMessageRole.user, second: 90),
        ],
      );
      expect(stats.source, SessionStatsSource.agentReported);
      expect(stats.turns, 2);
      expect(stats.replies, 1);
      expect(stats.toolCalls, 2);
      expect(stats.toolCallsByName, {'Read': 1, 'Read a file': 1});
      expect(stats.span, const Duration(seconds: 90));
      // The protocol carries no token tally, and none is invented.
      expect(stats.tokens.isUnknown, isTrue);
      expect(stats.contextWindow, isNull);
      expect(stats.contextUsedPerTurn, isNull);
      expect(stats.reportedCost, isNull);
    });

    test('the agent\'s usage gives the context, its series and its cost', () {
      final stats = acpSessionStats(
        rows: const [],
        usage: SessionUsage(
          sessionId: 's1',
          contextUsed: 2600,
          contextSize: 200000,
          costAmount: 0.5,
          costCurrency: 'USD',
          turns: const [
            SessionUsageTurn(contextUsed: 1800, contextSize: 200000),
            SessionUsageTurn(contextUsed: 2600, contextSize: 200000),
          ],
          updatedAt: t0,
        ),
      );
      expect(stats.lastPromptTokens, 2600);
      expect(stats.contextWindow, 200000);
      expect(stats.contextUsedPerTurn, [1800, 2600]);
      expect(
        stats.reportedCost,
        const ReportedCost(amount: 0.5, currency: 'USD'),
      );
      expect(stats.turns, 0);
    });
  });

  group('SessionRecordReadings', () {
    late AppDatabase db;

    setUp(() {
      db = AppDatabase.memory();
      db.execute('PRAGMA foreign_keys = OFF;');
      db.execute(
        'INSERT INTO sessions (id, repository_id, agent_installation_id, '
        'title, use_worktree, status, created_at) '
        "VALUES ('s1', 'r1', 'a1', 'T', 0, 'running', "
        "'2026-10-02T12:00:00.000Z');",
      );
    });
    tearDown(() => db.close());

    SessionRecordReadings readings({
      required String agentId,
      SessionMessageDao? messages,
      SessionUsageDao? usage,
      bool Function(String sessionId)? speaksAcp,
    }) => SessionRecordReadings(
      lookUp: (_) async => (path: null, agentId: agentId, absence: null),
      registry: AgentRegistry.builtIn,
      sessions: SessionDao(db),
      rows: CheckoutRows(db),
      runners: const CommandRunnerFactory(),
      messages: messages,
      usage: usage,
      speaksAcp: speaksAcp,
    );

    test('an ACP agent a person added, which the shipped registry does not '
        'know, answers from the rows too', () async {
      final messages = SessionMessageDao(db);
      messages.append(row('m1', SessionMessageRole.user));
      final reading = (await readings(
        agentId: 'my-own-acp-agent',
        messages: messages,
        speaksAcp: (sessionId) => sessionId == 's1',
      ).stats(const SessionStatsRead(['s1']))).sessions['s1']!;
      expect(reading.gap, SessionStatsGap.none);
      expect(reading.stats!.turns, 1);
    });

    test('an ACP session answers from the rows and usage kept here', () async {
      final messages = SessionMessageDao(db);
      messages.append(row('m1', SessionMessageRole.user));
      messages.append(row('m2', SessionMessageRole.agent));
      SessionUsageDao(db).recordTurn(
        's1',
        const SessionUsageTurn(contextUsed: 900, contextSize: 8000),
        at: t0,
      );
      final acp = AgentRegistry.builtIn.adapters
          .firstWhere((adapter) => adapter.acp != null)
          .id;
      final reading = (await readings(
        agentId: acp,
        messages: messages,
        usage: SessionUsageDao(db),
      ).stats(const SessionStatsRead(['s1'], lifetime: true))).sessions['s1']!;
      expect(reading.gap, SessionStatsGap.none);
      expect(reading.stats!.turns, 1);
      expect(reading.stats!.lastPromptTokens, 900);
      expect(reading.stats!.contextUsedPerTurn, [900]);
      expect(reading.lifetime, isNull);
      expect(
        reading.lifetimeGap,
        LifetimeStatsUnavailable.agentKeepsNoAggregate,
      );
    });

    test('an ACP session on a server keeping no rows has no counts', () async {
      final acp = AgentRegistry.builtIn.adapters
          .firstWhere((adapter) => adapter.acp != null)
          .id;
      final reading = (await readings(
        agentId: acp,
      ).stats(const SessionStatsRead(['s1']))).sessions['s1']!;
      expect(reading.gap, SessionStatsGap.agentKeepsNoCounts);
    });

    test('a terminal agent is still read from its record', () async {
      final reading = (await readings(
        agentId: AgentIds.claudeCode,
        messages: SessionMessageDao(db),
      ).stats(const SessionStatsRead(['s1']))).sessions['s1']!;
      // No file for it: the record is not found, not the rows counted.
      expect(reading.gap, SessionStatsGap.recordNotFound);
    });
  });
}
