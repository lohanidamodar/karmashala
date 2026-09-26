import 'package:agent_cli/descriptors.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/mcp/inventory_tools.dart';
import 'package:karmashala_conversations/karmashala_conversations.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_session/session.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/fake_data_server.dart';

/// **`session_search`, called the way an agent calls it.** Asserted on what
/// comes back, never on the schema — the golden file holds that. The search
/// itself is the server's (`server/test/data/conversations_handler_test.dart`);
/// this is what the tool asks of it and makes of the answer.
void main() {
  late FakeDataServer server;
  late InventoryTools tools;

  setUp(() async {
    server = FakeDataServer();
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    server.installationRows.insert(
      agentInstallation(agentId: AgentIds.claudeCode),
    );
    final container = ProviderContainer(
      overrides: [
        await server.override(),
        clockProvider.overrideWithValue(FixedClock(testTime)),
      ],
    );
    addTearDown(container.dispose);
    tools = InventoryTools(container);
  });

  void said(String session, String conversation, List<String> turns) {
    server.sessionRows.insert(
      Session(
        id: session,
        repositoryId: 'r1',
        agentInstallationId: 'a1',
        title: 'Title of $session',
        useWorktree: false,
        status: SessionStatus.running,
        createdAt: testTime,
        externalSessionId: conversation,
      ),
    );
    server.conversations.add(conversation, [
      for (var i = 0; i < turns.length; i++)
        ConversationTurn(ordinal: i * 2, role: 'user', text: turns[i]),
    ], indexedAt: testTime);
  }

  Future<Map<String, Object?>> call(Map<String, Object?> args) async =>
      (await tools.call('session_search', args))! as Map<String, Object?>;

  List<Map<String, Object?>> results(Map<String, Object?> answer) =>
      (answer['results']! as List).cast<Map<String, Object?>>();

  test(
    'finds the session a phrase was said in, by our id and its own',
    () async {
      said('s1', 'conv-1', ['boot', 'we fixed the stripe webhook signature']);
      said('s2', 'conv-2', ['nothing relevant here']);

      final answer = await call({'query': 'stripe webhook'});

      final hit = results(answer).single;
      expect(hit['sessionId'], 's1');
      expect(hit['conversationId'], 'conv-1');
      expect(hit['title'], 'Title of s1');
      expect(hit['kind'], 'native');
      expect(hit['match'], 'allWords');
      expect(hit['turn'], 2);
      expect(hit['excerpt'], contains('stripe webhook'));
      expect(hit['indexedAt'], testTime.toIso8601String());
      expect(answer['nextCursor'], isNull);
    },
  );

  test('asks the server to catch up before it searches', () async {
    said('s1', 'conv-1', ['boot']);
    server.conversations.onCatchUp = () => server.conversations.say(
      'conv-1',
      'appended since the last reading',
      ordinal: 4,
    );

    final answer = await call({'query': 'appended since'});

    expect(server.conversations.catchUps, 1);
    expect(results(answer).single['sessionId'], 's1');
  });

  test('sessionId narrows the search to that session', () async {
    said('s1', 'conv-1', ['the flaky test']);
    said('s2', 'conv-2', ['the flaky test again']);

    final answer = await call({'query': 'flaky', 'sessionId': 's2'});

    expect(results(answer).map((r) => r['sessionId']), ['s2']);
    expect(server.conversations.searches.last.filter.conversationId, 'conv-2');
  });

  test('the rest of the filter and the page travel to the server', () async {
    said('s1', 'conv-1', ['the cache note']);

    await call({
      'query': 'cache',
      'cli': AgentIds.claudeCode,
      'projectId': 'p1',
      'repositoryId': 'r1',
      'after': '2026-09-01T00:00:00Z',
      'before': '2026-10-01T00:00:00Z',
      'limit': 2,
      'cursor': 'next-page',
    });

    final asked = server.conversations.searches.single;
    expect(asked.limit, 2);
    expect(asked.cursor, 'next-page');
    expect(asked.filter.cli, AgentIds.claudeCode);
    expect(asked.filter.projectId, 'p1');
    expect(asked.filter.repositoryId, 'r1');
    expect(asked.filter.after, DateTime.utc(2026, 9));
    expect(asked.filter.before, DateTime.utc(2026, 10));
  });

  test('a cursor the server refuses is the caller\'s to fix', () async {
    said('s1', 'conv-1', ['the cache note']);
    server.conversations.refuseSearches = const DataRefused.invalid(
      'The conversation index changed since that page was served. Search '
      'again without a cursor.',
    );

    await expectLater(
      call({'query': 'cache', 'cursor': 'old'}),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('Search again without a cursor'),
        ),
      ),
    );
  });

  test(
    'refuses what it cannot search for, rather than answering nothing',
    () async {
      await expectLater(call({'query': 'x'}), throwsArgumentError);
      await expectLater(
        call({'query': 'cache', 'cli': 'no-such-agent'}),
        throwsArgumentError,
      );
      await expectLater(
        call({'query': 'cache', 'sessionId': 'missing'}),
        throwsArgumentError,
      );
      await expectLater(
        call({'query': 'cache', 'after': 'yesterday'}),
        throwsArgumentError,
      );
      expect(server.conversations.searches, isEmpty);
      expect(server.conversations.catchUps, 0);
    },
  );
}
