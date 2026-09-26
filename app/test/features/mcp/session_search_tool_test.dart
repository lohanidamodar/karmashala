import 'package:agent_cli/descriptors.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/cli_detection/data/conversation_index_dao.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/mcp/inventory_tools.dart';
import 'package:karmashala_projects/store.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_store/database.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// **`session_search`, called the way an agent calls it.** Asserted on what
/// comes back, never on the schema — the golden file holds that.
void main() {
  late AppDatabase db;
  late ConversationIndexDao index;
  late InventoryTools tools;

  setUp(() {
    db = AppDatabase.memory();
    index = ConversationIndexDao(db);
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    AgentInstallationDao(
      db,
    ).insert(agentInstallation(agentId: AgentIds.claudeCode));
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
      ],
    );
    addTearDown(container.dispose);
    tools = InventoryTools(container);
  });
  tearDown(() => db.close());

  void said(String session, String conversation, List<String> turns) {
    SessionDao(db).insert(
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
    index.replaceTurns(
      sessionId: conversation,
      cli: AgentIds.claudeCode,
      filePath: 'C:/store/$conversation.jsonl',
      turns: [
        for (var i = 0; i < turns.length; i++)
          ConversationTurn(ordinal: i * 2, role: 'user', text: turns[i]),
      ],
      indexedAt: testTime,
    );
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
      expect(hit['match'], 'phrase');
      expect(hit['turn'], 2);
      expect(hit['excerpt'], contains('stripe webhook'));
      expect(answer['nextCursor'], isNull);
    },
  );

  test('sessionId narrows the search to that session', () async {
    said('s1', 'conv-1', ['the flaky test']);
    said('s2', 'conv-2', ['the flaky test again']);

    final answer = await call({'query': 'flaky', 'sessionId': 's2'});

    expect(results(answer).map((r) => r['sessionId']), ['s2']);
  });

  test(
    'pages with a cursor, and refuses one the index has moved past',
    () async {
      for (var i = 0; i < 3; i++) {
        said('s$i', 'conv-$i', ['the cache note $i']);
      }

      final first = await call({'query': 'cache', 'limit': 2});
      expect(results(first), hasLength(2));
      final cursor = first['nextCursor']! as String;

      final second = await call({
        'query': 'cache',
        'limit': 2,
        'cursor': cursor,
      });
      expect(results(second), hasLength(1));
      expect(
        {...results(first), ...results(second)}.map((r) => r['sessionId']),
        unorderedEquals(['s0', 's1', 's2']),
      );

      said('s9', 'conv-9', ['a cache note written between pages']);
      await expectLater(
        call({'query': 'cache', 'limit': 2, 'cursor': cursor}),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('Search again without a cursor'),
          ),
        ),
      );
    },
  );

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
    },
  );
}
