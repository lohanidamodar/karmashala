import 'package:agent_cli/descriptors.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala/src/core/data/data_client.dart';
import 'package:karmashala/src/core/data/data_providers.dart';
import 'package:karmashala/src/features/explorer/application/project_working.dart';
import 'package:karmashala/src/features/running/application/running_providers.dart';
import 'package:karmashala/src/features/notifications/application/session_statuses.dart';
import 'package:karmashala/src/features/sessions/data/sessions_data.dart';
import 'package:karmashala_core/util.dart' show SystemClock;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_notifications/watched.dart';
import 'package:karmashala_session/session.dart';

import '../../support/fake_data_server.dart';

BotApproval approval(String id, {String sessionId = 'bot-1'}) => BotApproval(
  id: id,
  sessionId: sessionId,
  tool: 'worktree_remove',
  arguments: const {'path': 'x'},
  summary: 'Remove the worktree x',
  state: BotApprovalState.pending,
  requestedAt: DateTime.utc(2026, 11, 2),
  expiresAt: DateTime.utc(2026, 11, 2, 0, 10),
);

Future<void> settle() => pumpEventQueue();

SessionStatusEntry working(String openId) => SessionStatusEntry(
  session: WatchedSession(
    key: AgentSessionKey('claudeCode', openId),
    label: 'Bot',
    openId: openId,
    imported: false,
  ),
  report: AgentStatusReport(
    agentId: 'claudeCode',
    sessionId: openId,
    status: AgentActivityStatus.working,
    source: AgentStatusSource.hook,
    observedAt: DateTime.utc(2026, 11, 2),
  ),
);

void main() {
  late FakeDataServer server;
  late DataClient client;

  setUp(() async {
    server = FakeDataServer();
    client = await server.connect();
  });

  Future<void> follow() async {
    client.applyBot((await client.send(const BotSubscribe())).value);
  }

  group('the copy', () {
    test(
      'nothing is known until a link follows, and a follow makes no row',
      () async {
        expect(client.bot, isNull);
        await follow();
        expect(client.bot, isNotNull);
        expect(client.bot!.session, isNull);
        expect(server.bot.session, isNull);
      },
    );

    test(
      'the row, the agent and the approvals move as they are told',
      () async {
        await follow();
        server.bot.rowMoved(server.bot.makeRow());
        await settle();
        expect(client.bot!.session?.id, 'bot-1');
        expect(client.botIds, contains('bot-1'));

        server.bot.ask(approval('a'));
        await settle();
        expect(client.bot!.approvals.map((a) => a.id), ['a']);

        server.bot.tell([
          const BotAgentChanged(
            agentId: 'codex-acp',
            agentSetting: 'codex-acp',
          ),
        ]);
        await settle();
        expect(client.bot!.agentId, 'codex-acp');
        expect(client.bot!.agentSetting, 'codex-acp');
        expect(client.bot!.agents, hasLength(2), reason: 'the list stays');
      },
    );

    test('an answered approval leaves, whoever answered', () async {
      await follow();
      server.bot.rowMoved(server.bot.makeRow());
      server.bot.ask(approval('a'));
      server.bot.ask(approval('b'));
      await settle();
      final other = await server.dial();
      await other!.send(const BotApprovalAnswer('a', approve: false));
      await settle();
      expect(client.bot!.approvals.map((a) => a.id), ['b']);
    });

    test('a cleared row goes back to no row, and its id stays known', () async {
      await follow();
      final row = server.bot.makeRow();
      server.bot.rowMoved(row);
      server.bot.ask(approval('a'));
      await settle();

      server.bot.rowMoved(row.copyWith(archivedAt: DateTime.utc(2026, 11, 3)));
      await settle();
      expect(client.bot!.session, isNull);
      expect(client.bot!.approvals, isEmpty);
      expect(client.botIds, contains('bot-1'));
    });

    test('a late word about a cleared row leaves the new row alone', () async {
      await follow();
      final old = server.bot.makeRow();
      server.bot.rowMoved(old);
      final fresh = old.copyWith(id: 'bot-2');
      server.bot.rowMoved(fresh);
      await settle();
      server.bot.tell([
        BotRowChanged(old.copyWith(archivedAt: DateTime.utc(2026, 11, 3))),
      ]);
      await settle();
      expect(client.bot!.session?.id, 'bot-2');
    });

    test(
      'a follow is lost with its link, and a new one replaces the copy',
      () async {
        await follow();
        server.bot.rowMoved(server.bot.makeRow());
        server.bot.ask(approval('old'));
        await settle();

        server.stop();
        await settle();
        expect(client.bot, isNotNull, reason: 'kept to draw while away');
        server.bot.approvals.clear();
        server.start();
        client.retry();
        for (var i = 0; i < 200; i++) {
          if (client.connection.state == DataLinkState.connected) break;
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(client.connection.state, DataLinkState.connected);

        server.bot.ask(approval('unheard'));
        await settle();
        expect(client.bot!.approvals.map((a) => a.id), [
          'old',
        ], reason: 'a new link follows nothing until it asks');

        await follow();
        expect(client.bot!.approvals.map((a) => a.id), ['unheard']);
      },
    );
  });

  group('hidden from every list', () {
    test('a lookup finds the bot; no list does', () async {
      final sessions = SessionsData(client);
      await follow();
      expect(sessions.getById('bot-1'), isNull);
      server.bot.rowMoved(server.bot.makeRow());
      await settle();
      expect(sessions.getById('bot-1')?.isBot, isTrue);
      expect(sessions.getAll(), isEmpty);
      expect(client.sessions['bot-1'], isNull);
    });

    test(
      'statuses: Running and the lists leave it out, the panel reads it',
      () async {
        final statuses = SessionStatuses(client, clock: const SystemClock());
        addTearDown(statuses.dispose);
        final moved = <String>[];
        final sub = statuses.statusChanges.listen(
          (e) => moved.add(e.session.openId),
        );
        addTearDown(sub.cancel);
        await follow();
        server.bot.rowMoved(server.bot.makeRow());
        await settle();

        server.attention
          ..statusOf('bot-1', AgentActivityStatus.working)
          ..statusOf('s1', AgentActivityStatus.working);
        await settle();

        expect(moved, ['s1']);
        expect(statuses.entries.map((e) => e.session.openId), ['s1']);
        expect(statuses.trackedCount, 1);
        expect(
          statuses.reportForOpenId('bot-1')?.status,
          AgentActivityStatus.working,
        );
      },
    );

    test('Running leaves out the processes of a bot row', () {
      final reading = RunningController.withoutBot(
        RunningReading(
          serverPid: 1,
          checkedAt: DateTime.utc(2026, 11, 2),
          processes: const [
            RunningProcess(
              pid: 2,
              parent: 1,
              role: RunningRole.child,
              name: 'bot',
              agentSessionId: 'bot-1',
            ),
            RunningProcess(
              pid: 3,
              parent: 1,
              role: RunningRole.child,
              name: 'work',
              agentSessionId: 's1',
            ),
          ],
        ),
        const {'bot-1'},
      );
      expect(reading.processes.map((p) => p.pid), [3]);
    });

    test('a status greeted ahead of the row leaves Working', () async {
      final container = ProviderContainer(
        overrides: [dataClientProvider.overrideWithValue(client)],
      );
      addTearDown(container.dispose);
      final sub = container.listen(workingSessionsProvider, (_, _) {});
      addTearDown(sub.close);
      server.attention.statusOf('bot-1', AgentActivityStatus.working);
      await settle();
      expect(sub.read(), {'bot-1'}, reason: 'not yet known to be the bot');

      server.bot.session = server.bot.makeRow();
      await follow();
      expect(sub.read(), isEmpty);
    });

    test('a status greeted ahead of the row is taken back', () async {
      final statuses = SessionStatuses(client, clock: const SystemClock());
      addTearDown(statuses.dispose);
      final removed = <String>[];
      final sub = statuses.removals.listen(removed.add);
      addTearDown(sub.cancel);
      server.bot
        ..session = server.bot.makeRow()
        ..greeting = [SessionStatusChanged(working('bot-1'))];

      await follow();
      expect(statuses.entries, isEmpty);
      expect(removed, ['bot-1']);
    });
  });
}
