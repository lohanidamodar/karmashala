import 'package:agent_cli/descriptors.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/reveal_session.dart';
import 'package:karmashala/src/core/data/data_client.dart';
import 'package:karmashala/src/core/data/data_providers.dart';
import 'package:karmashala/src/features/bot/application/bot_providers.dart';
import 'package:karmashala/src/features/notifications/application/attention_inbox.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_notifications/attention.dart';
import 'package:karmashala_notifications/watched.dart';

import '../../support/fixtures.dart';
import 'bot_support.dart';

InboxItem botItem(
  String id, {
  InboxItemKind kind = InboxItemKind.botApproval,
}) => InboxItem(
  id: id,
  session: WatchedSession(
    key: const AgentSessionKey('bot', 'bot-1'),
    label: 'Bot',
    openId: 'bot-1',
    imported: false,
  ),
  kind: kind,
  at: DateTime.utc(2026, 11, 2),
);

void main() {
  late BotRig rig;

  setUp(() => rig = BotRig());

  group('following', () {
    test('a server with a bot is followed, and nothing is made', () async {
      final container = await rig.container();
      expect(rig.bot.asked.whereType<BotSubscribe>(), hasLength(1));
      expect(rig.bot.asked.whereType<BotOpen>(), isEmpty);
      expect(rig.bot.session, isNull);
      expect(container.read(botStateProvider), isNotNull);
    });

    test('an older server is never asked', () async {
      final container = await rig.container(features: const {'sessions.send'});
      expect(rig.bot.asked, isEmpty);
      expect(container.read(botStateProvider), isNull);
    });

    test('a new link asks again', () async {
      final container = await rig.container();
      final client = container.read(dataClientProvider);
      rig.server.stop();
      await pumpEventQueue();
      rig.server.start();
      client.retry();
      for (var i = 0; i < 200; i++) {
        if (rig.bot.asked.whereType<BotSubscribe>().length == 2) break;
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(client.connection.state, DataLinkState.connected);
      expect(rig.bot.asked.whereType<BotSubscribe>(), hasLength(2));
    });

    test('agents found after the follow reach the panel', () async {
      rig.bot.agents = const [];
      final container = await rig.container();
      expect(container.read(botStateProvider)!.agents, isEmpty);

      // The server finished looking: this is how a fresh start goes.
      rig.bot.agents = const [
        BotAgent(agentId: 'claude-acp', name: 'Claude', installationId: 'a1'),
      ];
      final client = container.read(dataClientProvider);
      client.installations.applyAt(
        'a9',
        agentInstallation(id: 'a9'),
        rig.server.revision + 1,
      );
      await pumpEventQueue();

      expect(container.read(botStateProvider)!.agents, hasLength(1));
      expect(rig.bot.session, isNull, reason: 'reading makes nothing');
      expect(rig.bot.asked.whereType<BotOpen>(), isEmpty);
    });

    test('a follow refused says why', () async {
      rig.bot.subscribeRefusal = const DataRefused.unavailable('no bot today');
      final container = await rig.container();
      expect(container.read(botReadFailureProvider), 'no bot today');
    });
  });

  group('the first message', () {
    test('makes the row, then sends as any session does', () async {
      final container = await rig.container();
      await container.read(botActionsProvider).sendFirst('hello');

      expect(rig.bot.asked.whereType<BotOpen>(), hasLength(1));
      expect(rig.server.sessionWork.sent.map((s) => (s.sessionId, s.text)), [
        ('bot-1', 'hello'),
      ]);
      expect(container.read(botSessionIdProvider), 'bot-1');
    });

    test('a refusal is its own words, and the box comes back', () async {
      rig.bot.openRefusal = const DataRefused.unavailable(
        'no agent can run the bot',
      );
      final container = await rig.container();
      await expectLater(
        container.read(botActionsProvider).sendFirst('hello'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'no agent can run the bot',
          ),
        ),
      );
      expect(container.read(botFirstSendProvider), isFalse);
      expect(rig.server.sessionWork.sent, isEmpty);
    });

    test('the box stays up while it goes', () async {
      final container = await rig.container();
      final seen = <bool>[];
      container.listen(botFirstSendProvider, (_, now) => seen.add(now));
      await container.read(botActionsProvider).sendFirst('hello');
      expect(seen, [true, false]);
    });
  });

  group('the agent, Clear and approvals', () {
    test('a pick is one call', () async {
      final container = await rig.container();
      await container.read(botActionsProvider).setAgent('codex-acp');
      expect(
        rig.bot.asked.whereType<BotAgentSet>().single.agentId,
        'codex-acp',
      );
      expect(container.read(botStateProvider)?.agentSetting, 'codex-acp');
      expect(rig.server.requests, isNot(contains('sessions.switchAgent')));

      await container.read(botActionsProvider).setAgent(null);
      expect(container.read(botStateProvider)?.agentSetting, isNull);
    });

    test('refused mid-turn, the refusal comes back', () async {
      rig.bot.agentRefusal = DataRefused(
        DataRefusalCode.conflict,
        'a turn is running',
      );
      final container = await rig.container();
      await expectLater(
        container.read(botActionsProvider).setAgent('codex-acp'),
        throwsA(isA<DataRefused>()),
      );
    });

    test('Clear goes back to no row', () async {
      botRow(rig);
      final container = await rig.container();
      expect(container.read(botSessionIdProvider), 'bot-1');
      await container.read(botActionsProvider).clear();
      expect(container.read(botSessionIdProvider), isNull);
    });

    test('an answer takes the card away', () async {
      botRow(rig);
      rig.bot.approvals.add(approvalOf('a'));
      final container = await rig.container();
      expect(container.read(botStateProvider)!.approvals, hasLength(1));
      await container.read(botActionsProvider).answer('a', approve: true);
      expect(container.read(botStateProvider)!.approvals, isEmpty);
      expect(
        rig.bot.asked.whereType<BotApprovalAnswer>().single.approve,
        isTrue,
      );
    });
  });

  group('the dot', () {
    test('an approval, or a question, is the attention colour', () async {
      botRow(rig);
      final container = await rig.container();
      final sub = container.listen(botAttentionProvider, (_, _) {});
      expect(sub.read(), BotAttention.none);

      rig.bot.ask(approvalOf('a'));
      await pumpEventQueue();
      expect(sub.read(), BotAttention.waiting);

      await container.read(botActionsProvider).answer('a', approve: false);
      await pumpEventQueue();
      expect(sub.read(), BotAttention.none);

      rig.server.attention.statusOf(
        'bot-1',
        AgentActivityStatus.awaitingApproval,
        waiting: AgentWaitKind.question,
      );
      await pumpEventQueue();
      expect(sub.read(), BotAttention.waiting);
    });

    test('a reply while shut is unread, until it is opened', () async {
      botRow(rig);
      final container = await rig.container();
      final sub = container.listen(botAttentionProvider, (_, _) {});
      container.listen(botUnreadProvider, (_, _) {});

      rig.server.attention.statusOf('bot-1', AgentActivityStatus.working);
      await pumpEventQueue();
      expect(sub.read(), BotAttention.none);
      rig.server.attention.statusOf('bot-1', AgentActivityStatus.idle);
      await pumpEventQueue();
      expect(sub.read(), BotAttention.unread);

      container.read(botPanelProvider.notifier).open();
      await pumpEventQueue();
      expect(sub.read(), BotAttention.none);
    });

    test('a reply read with the panel up is not unread', () async {
      botRow(rig);
      final container = await rig.container();
      final sub = container.listen(botAttentionProvider, (_, _) {});
      container.listen(botUnreadProvider, (_, _) {});
      container.read(botPanelProvider.notifier).open();

      rig.server.attention.statusOf('bot-1', AgentActivityStatus.working);
      await pumpEventQueue();
      rig.server.attention.statusOf('bot-1', AgentActivityStatus.idle);
      await pumpEventQueue();
      container.read(botPanelProvider.notifier).close();
      await pumpEventQueue();
      expect(sub.read(), BotAttention.none);
    });
  });

  group('what opens the panel', () {
    test('a reveal of the bot does, and goes nowhere else', () async {
      botRow(rig);
      final container = await rig.container();
      final went = revealSession(container, openId: 'bot-1');
      expect(went, SessionReveal.bot);
      expect(container.read(botPanelProvider), isTrue);
    });

    test('a reveal of a cleared row does too', () async {
      botRow(rig);
      final container = await rig.container();
      await container.read(botActionsProvider).clear();
      expect(revealSession(container, openId: 'bot-1'), SessionReveal.bot);
    });

    test('the server telling this window to open it does', () async {
      botRow(rig);
      final container = await rig.container();
      container.listen(attentionInboxProvider, (_, _) {});
      rig.bot.tell([const InboxOpenWanted(openId: 'bot-1', imported: false)]);
      await pumpEventQueue();
      expect(container.read(botPanelProvider), isTrue);
    });

    test(
      'an inbox item opens it without asking a session to be shown',
      () async {
        botRow(rig);
        final container = await rig.container();
        container.read(attentionInboxProvider.notifier).openBot(botItem('i1'));
        await pumpEventQueue();
        expect(container.read(botPanelProvider), isTrue);
        expect(rig.server.attention.opened, isEmpty);
        expect(rig.server.attention.viewedAsked.single, ['bot-1']);
      },
    );

    test('with the panel up the bot is looked at', () async {
      botRow(rig);
      final container = await rig.container();
      container.listen(attentionInboxProvider, (_, _) {});
      container.read(botPanelProvider.notifier).open();
      await pumpEventQueue();
      expect(rig.server.attention.seenAsked.last, contains('bot-1'));
    });
  });
}
