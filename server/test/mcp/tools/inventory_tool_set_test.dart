import 'package:agent_cli/discovery.dart' show AgentInstallation;
import 'package:agent_cli/process.dart' show EnvironmentPath;
import 'package:agent_cli/read.dart' show ImportedSession;
import 'package:karmashala_automations/resumes.dart';
import 'package:karmashala_automations/store.dart';
import 'package:karmashala_conversations/karmashala_conversations.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/src/mcp/tools/inventory_tool_set.dart';
import 'package:karmashala_host/src/sessions/session_active_models.dart';
import 'package:test/test.dart';

import 'tool_harness.dart';

/// `list_projects`, `list_sessions`, `list_agents` and `session_search`, run
/// by the server (slice 2b) from the store and its own conversation index.
/// Asserted on what comes back; the search itself is the index's
/// (`test/data/conversations_handler_test.dart`).
void main() {
  late ToolHarness h;
  late InventoryToolSet tools;

  setUp(() {
    h = ToolHarness();
    tools = InventoryToolSet(h.context);
  });
  tearDown(() => h.dispose());

  Future<List<Map<String, Object?>>> list(
    String tool, [
    Map<String, dynamic> arguments = const {},
  ]) async => ((await h.call(tools, tool, arguments))! as List)
      .cast<Map<String, Object?>>();

  void importHistory(String id, String conversation, {String cli = 'codex'}) =>
      h.client.handle(
        ImportedAdd(
          ImportedSession(
            id: id,
            repositoryId: 'r1',
            cli: cli,
            externalId: conversation,
            environmentId: h.here.id,
            filePath: '/nowhere/$conversation.jsonl',
            storeHome: '/home',
            isSubagent: false,
            preview: 'the appwrite migration',
            createdAt: h.now,
            title: 'Imported $id',
          ),
        ),
      );

  group('list_projects and list_agents', () {
    test('every project, by name, with where it lives', () async {
      expect(await list('list_projects'), [
        {
          'id': 'p1',
          'name': 'Demo',
          'environmentId': h.here.id,
          'path': '/src/p1',
        },
        {
          'id': 'p2',
          'name': 'Karmashala',
          'environmentId': h.here.id,
          'path': '/src/p2',
        },
      ]);
    });

    test('every installed agent, as open_new_session takes it', () async {
      expect(await list('list_agents'), [
        {
          'agentInstallationId': 'a1',
          'cli': 'claudeCode',
          'agent': 'Claude Code',
          'form': 'terminal',
          'environmentId': h.here.id,
          'path': '/usr/local/bin/claude',
        },
      ]);
    });

    test('a chat form is its own row, named as the agent it is a form of', () {
      final terminal = h.context.agents.formsOf('claudeCode');
      expect(terminal.chatId, isNotNull);
      final row = tools.agentRow(
        AgentInstallation(
          id: 'c1',
          agentId: terminal.chatId!,
          executable: EnvironmentPath(
            environmentId: h.here.id,
            path: '/usr/local/bin/claude-agent-acp',
          ),
          createdAt: DateTime.utc(2026),
        ),
      );
      expect(row['cli'], terminal.chatId);
      expect(row['agent'], 'Claude Code');
      expect(row['form'], 'chat');
    });
  });

  group('list_sessions', () {
    test('native sessions and imported history, each saying which', () async {
      importHistory('i1', 'conv-i1');
      final rows = await list('list_sessions');
      expect(
        [for (final r in rows) (r['id'], r['kind'])],
        [('s1', 'native'), ('s2', 'native'), ('i1', 'imported')],
      );
      final s1 = rows.first;
      expect(s1['title'], 'Fix login');
      expect(s1['cli'], 'claudeCode');
      expect(s1['agent'], 'Claude Code');
      expect(s1['project'], 'Demo');
      expect(s1['repository'], 'app');
      expect(s1['status'], 'running');
      expect(s1, isNot(contains('scheduledResume')));
      expect(rows.last['title'], 'Imported i1');
      expect(rows.last['externalId'], 'conv-i1');
    });

    test('each native session names the model its agent last said it runs, '
        'or says it is not recorded — never a default', () async {
      h.context.activeModels = SessionActiveModels(announce: (_) {})
        ..report('s1', 'claude-opus-5-5', source: ActiveModelSource.record);
      final rows = await list('list_sessions');
      expect(
        rows.firstWhere((r) => r['id'] == 's1')['model'],
        'claude-opus-5-5',
      );
      expect(rows.firstWhere((r) => r['id'] == 's2')['model'], 'not recorded');
    });

    test('filters by a substring and by the agent', () async {
      importHistory('i1', 'conv-i1');
      expect(
        [
          for (final r in await list('list_sessions', {'query': 'LOGIN'}))
            r['id'],
        ],
        ['s1'],
      );
      for (final spelling in ['fix-login', 'fix_login', 'FixLogin']) {
        expect(
          [
            for (final r in await list('list_sessions', {'query': spelling}))
              r['id'],
          ],
          ['s1'],
          reason: 'separators and case do not matter: $spelling',
        );
      }
      expect(
        [
          for (final r in await list('list_sessions', {'query': 'appwrite'}))
            r['id'],
        ],
        ['i1'],
        reason: 'an imported session is matched on its preview too',
      );
      expect(
        [
          for (final r in await list('list_sessions', {'cli': 'codex'}))
            r['id'],
        ],
        ['i1'],
      );
      expect(
        [
          for (final r in await list('list_sessions', {'cli': 'Claude'}))
            r['id'],
        ],
        ['s1', 's2'],
        reason: 'an agent is named by what its adapter answers to',
      );
    });

    test('shows a waiting resume, read-only', () async {
      final fireAt = h.now.add(const Duration(hours: 2));
      ScheduledResumeDao(h.db).replaceFor(
        ScheduledResume(
          id: 'resume-1',
          sessionId: 's1',
          fireAt: fireAt,
          state: ScheduledResumeState.pending,
          scheduledAt: h.now,
        ),
        now: h.now,
      );
      final s1 = (await list('list_sessions')).first;
      expect(s1['scheduledResume'], {
        'state': 'pending',
        'fireAt': fireAt.toIso8601String(),
      });
    });
  });

  group('session_search', () {
    void said(String session, String conversation, List<String> turns) {
      h.addSession(
        session,
        title: 'Title of $session',
        conversation: conversation,
      );
      h.service.conversations.dao.replaceTurns(
        sessionId: conversation,
        cli: 'claudeCode',
        filePath: '/nowhere/$conversation.jsonl',
        turns: [
          for (var i = 0; i < turns.length; i++)
            ConversationTurn(ordinal: i * 2, role: 'user', text: turns[i]),
        ],
        indexedAt: h.now,
      );
    }

    Future<Map<String, Object?>> search(Map<String, dynamic> args) =>
        h.map(tools, 'session_search', args);

    List<Map<String, Object?>> results(Map<String, Object?> answer) =>
        (answer['results']! as List).cast<Map<String, Object?>>();

    test('finds the session a phrase was said in, by our id and its '
        'own', () async {
      said('s3', 'conv-1', ['boot', 'we fixed the stripe webhook signature']);
      said('s4', 'conv-2', ['nothing relevant here']);

      final answer = await search({'query': 'stripe webhook'});

      final hit = results(answer).single;
      expect(hit['sessionId'], 's3');
      expect(hit['conversationId'], 'conv-1');
      expect(hit['title'], 'Title of s3');
      expect(hit['kind'], 'native');
      expect(hit['agent'], 'Claude Code');
      expect(hit['turn'], 2);
      expect(hit['excerpt'], contains('stripe webhook'));
      expect(hit['indexedAt'], h.now.toIso8601String());
      expect(answer['nextCursor'], isNull);
      expect(answer['note'], startsWith('Best first.'));
    });

    test('nothing indexed says what is indexed', () async {
      final answer = await search({'query': 'stripe webhook'});
      expect(results(answer), isEmpty);
      expect(answer['note'], startsWith('Nothing indexed matches.'));
    });

    test('sessionId narrows the search to that session', () async {
      said('s3', 'conv-1', ['the flaky test']);
      said('s4', 'conv-2', ['the flaky test again']);

      final answer = await search({'query': 'flaky', 'sessionId': 's4'});
      expect(results(answer).map((r) => r['sessionId']), ['s4']);
    });

    test('a cursor the index has moved past is the caller\'s to fix', () async {
      said('s3', 'conv-1', ['the cache note']);
      await expectLater(
        search({'query': 'cache', 'cursor': 'not-a-cursor'}),
        throwsA(isA<StateError>()),
      );
    });

    test('refuses what it cannot search for, rather than answering '
        'nothing', () async {
      await expectLater(search({'query': 'x'}), throwsArgumentError);
      await expectLater(
        search({'query': 'cache', 'cli': 'no-such-agent'}),
        throwsA(
          isA<ArgumentError>().having(
            (e) => '$e',
            'text',
            contains('Unknown cli "no-such-agent". list_agents has the ids.'),
          ),
        ),
      );
      await expectLater(
        search({'query': 'cache', 'sessionId': 'missing'}),
        throwsA(
          isA<ArgumentError>().having(
            (e) => '$e',
            'text',
            contains('No session with id missing'),
          ),
        ),
      );
      await expectLater(
        search({'query': 'cache', 'after': 'yesterday'}),
        throwsA(
          isA<ArgumentError>().having(
            (e) => '$e',
            'text',
            contains('after must be an ISO-8601 date or instant.'),
          ),
        ),
      );
    });
  });
}
