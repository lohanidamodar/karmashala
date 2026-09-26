import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/cli_detection/application/conversation_indexer.dart';
import 'package:karmashala/src/features/cli_detection/application/session_search.dart';
import 'package:karmashala/src/features/cli_detection/data/conversation_index_dao.dart';
import 'package:karmashala/src/features/cli_detection/data/imported_session_dao.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_store/database.dart';
import 'package:sqlite3/sqlite3.dart' hide Session;

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/fake_data_server.dart';
import '../../support/workspace_mirror.dart';

class _CountingDatabase extends AppDatabase {
  _CountingDatabase() : super(sqlite3.openInMemory());

  final List<String> statements = [];

  @override
  List<Map<String, Object?>> query(
    String sql, [
    List<Object?> params = const [],
  ]) {
    statements.add(sql);
    return super.query(sql, params);
  }
}

/// **Session search: ranked, degrading, filtered and paged — over what the
/// index holds.** The DAO's own file covers the storage; this one covers the
/// service quick open and the `session_search` tool both call.
void main() {
  late _CountingDatabase db;
  late ConversationIndexDao dao;
  late MovableClock clock;
  late SessionSearchService search;
  var sessionCount = 0;

  setUp(() {
    db = _CountingDatabase();
    dao = ConversationIndexDao(db);
    clock = MovableClock(DateTime.utc(2026, 9, 21, 12));
    search = SessionSearchService(dao: dao, clock: clock);
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    final server = FakeDataServer()..mirrorInto(db);
    server.projectRows.insert(project());
    server.projectRows.insert(project(id: 'p2', name: 'Other', path: r'C:\o'));
    server.repositoryRows.insert(repository());
    server.repositoryRows.insert(
      repository(id: 'r2', projectId: 'p2', path: r'C:\o\x'),
    );
    AgentInstallationDao(
      db,
    ).insert(agentInstallation(agentId: AgentIds.claudeCode));
    sessionCount = 0;
  });
  tearDown(() => db.close());

  /// A session row on [conversation], so the index's hit has something to
  /// open, with [turns] indexed for it.
  void conversation(
    String id,
    List<String> turns, {
    String cli = AgentIds.claudeCode,
    String repositoryId = 'r1',
    DateTime? at,
    bool withSession = true,
  }) {
    if (withSession) {
      SessionDao(db).insert(
        Session(
          id: 's${sessionCount++}',
          repositoryId: repositoryId,
          agentInstallationId: 'a1',
          title: 'Session $id',
          useWorktree: false,
          status: SessionStatus.running,
          createdAt: testTime,
          externalSessionId: id,
        ),
      );
    }
    dao.replaceTurns(
      sessionId: id,
      cli: cli,
      filePath: 'C:/store/$id.jsonl',
      turns: [
        for (var i = 0; i < turns.length; i++)
          ConversationTurn(ordinal: i, role: 'user', text: turns[i], at: at),
      ],
      indexedAt: clock.now,
    );
  }

  List<String> ids(SessionSearchPage page) => [
    for (final hit in page.hits) hit.sessionId,
  ];

  group('ranking', () {
    test('BM25 decides the order, not which was indexed first', () {
      conversation('weak', [
        'a long ramble that mentions the webhook once among many other words '
            'about deployment and caching and the release train',
      ]);
      conversation('strong', ['webhook webhook: the webhook retries']);

      expect(ids(search.search('webhook')), ['strong', 'weak']);
      // The negative: the index's own order is the other way round, so the
      // answer above is the ranking's, not an accident of insertion.
      expect(dao.search('webhook').first.sessionId, 'weak');
    });

    test('one result per conversation, carrying how many turns matched', () {
      conversation('c1', ['stripe one', 'stripe two', 'stripe three']);

      final hits = search.search('stripe').hits;

      expect(hits, hasLength(1));
      expect(hits.single.matches, 3);
      expect(hits.single.excerpt, contains('stripe'));
    });
  });

  group('the cascade', () {
    test('the phrase comes first, the words apart after it', () {
      // Apart, but said many times, so on BM25 alone it would win.
      conversation('apart', [
        'webhook here, stripe there, webhook again, stripe again, webhook',
      ]);
      conversation('together', [
        'we fixed the stripe webhook signature check in a long afternoon',
      ]);

      final hits = search.search('stripe webhook').hits;

      expect([for (final h in hits) h.sessionId], ['together', 'apart']);
      expect(hits[0].tier, ConversationMatchTier.phrase);
      expect(hits[1].tier, ConversationMatchTier.allWords);
    });

    test('any word, when no conversation has them all', () {
      conversation('a', ['the stripe dashboard']);
      conversation('b', ['the webhook endpoint']);

      final hits = search.search('stripe webhook').hits;

      expect(hits.map((h) => h.sessionId), unorderedEquals(['a', 'b']));
      expect(hits.map((h) => h.tier).toSet(), {ConversationMatchTier.anyWord});
      // Without the cascade the query answers nothing at all.
      expect(dao.search('stripe webhook'), isEmpty);
    });

    test('a misspelt word is repaired to the indexed one', () {
      conversation('c1', ['the signature header was missing']);

      final hits = search.search('signatrue header').hits;

      expect(hits.single.sessionId, 'c1');
      expect(hits.single.tier, ConversationMatchTier.repaired);
      expect(search.repairsFor(['signatrue']), {'signatrue': 'signature'});
      // Too far from anything indexed is not repaired into something random.
      expect(search.repairsFor(['zqxwvyut']), isEmpty);
      expect(search.search('zqxwvyut').hits, isEmpty);
    });

    test('a query the strict tiers answer never reads the vocabulary', () {
      conversation('c1', ['the stripe webhook']);
      db.statements.clear();

      final page = search.search('stripe webhook');

      expect(page.hits, hasLength(1));
      expect(
        db.statements.where((s) => s.contains('conversation_turns_vocab')),
        isEmpty,
      );
      // And the negative: one that the strict tiers cannot answer does.
      search.search('stripe webhoko');
      expect(
        db.statements.where((s) => s.contains('conversation_turns_vocab')),
        isNotEmpty,
      );
    });
  });

  group('the excerpt', () {
    const long =
        'one two three four five six seven eight nine ten eleven twelve '
        'thirteen fourteen the stripe webhook failed on the signature check '
        'and then everything after it was fine for a long long while longer';

    test('is cut around the words searched for, with ellipses', () {
      final excerpt = conversationExcerpt(long, {'stripe', 'webhook'});

      expect(excerpt, contains('stripe webhook'));
      expect(excerpt, startsWith('…'));
      expect(excerpt, endsWith('…'));
      expect(excerpt, isNot(contains('one two')));
    });

    test('counts a word the last token is a prefix of', () {
      final excerpt = conversationExcerpt(long, const {}, prefix: 'signat');
      expect(excerpt, contains('signature'));
    });

    test('with nothing to find, is the start of the turn', () {
      final excerpt = conversationExcerpt(long, {'absent'});
      expect(excerpt, startsWith('one two'));
      expect(excerpt, endsWith('…'));
    });

    test('a short turn is the whole turn, uncut', () {
      expect(
        conversationExcerpt('the  stripe\nwebhook', {'stripe'}),
        'the stripe webhook',
      );
    });
  });

  test('a page the words answered is not padded with any-word hits', () {
    conversation('both', ['the stripe webhook']);
    conversation('one', ['only the stripe dashboard']);

    // "one" would be an any-word hit, but the strict tiers found "both".
    expect(ids(search.search('stripe webhook')), ['both']);
  });

  group('filters', () {
    test('by agent', () {
      conversation('claude', ['the flaky test']);
      conversation('codex', ['the flaky test'], cli: AgentIds.codex);

      expect(
        ids(
          search.search(
            'flaky',
            filter: const SessionSearchFilter(cli: AgentIds.codex),
          ),
        ),
        ['codex'],
      );
    });

    test('within one conversation', () {
      conversation('c1', ['the migration plan']);
      conversation('c2', ['the migration plan too']);

      expect(
        ids(
          search.search(
            'migration',
            filter: const SessionSearchFilter(conversationId: 'c2'),
          ),
        ),
        ['c2'],
      );
    });

    test('by project and by repository', () {
      conversation('here', ['release notes']);
      conversation('there', ['release notes'], repositoryId: 'r2');

      expect(
        ids(
          search.search(
            'release',
            filter: const SessionSearchFilter(projectId: 'p2'),
          ),
        ),
        ['there'],
      );
      expect(
        ids(
          search.search(
            'release',
            filter: const SessionSearchFilter(repositoryId: 'r1'),
          ),
        ),
        ['here'],
      );
    });

    test('by date, where an unrecorded time is never in range', () {
      conversation('old', ['the outage'], at: DateTime.utc(2026, 8, 1));
      conversation('new', ['the outage'], at: DateTime.utc(2026, 9, 20));
      conversation('undated', ['the outage']);

      expect(
        ids(
          search.search(
            'outage',
            filter: SessionSearchFilter(after: DateTime.utc(2026, 9, 1)),
          ),
        ),
        ['new'],
      );
      expect(
        ids(
          search.search(
            'outage',
            filter: SessionSearchFilter(before: DateTime.utc(2026, 9, 1)),
          ),
        ),
        ['old'],
      );
      expect(ids(search.search('outage')), hasLength(3));
    });

    test('a conversation no row names any more is not a result', () {
      conversation('orphan', ['said in a deleted session'], withSession: false);
      conversation('kept', ['said in a live one']);

      expect(ids(search.search('said')), ['kept']);
    });

    test('read-only history is a result', () {
      ImportedSessionDao(db).insertIfAbsent(
        ImportedSession(
          id: 'i1',
          repositoryId: 'r1',
          cli: AgentIds.claudeCode,
          externalId: 'hist',
          environmentId: 'windows',
          filePath: r'C:\store\hist.jsonl',
          storeHome: r'C:\store',
          isSubagent: false,
          preview: 'preview',
          createdAt: testTime,
        ),
      );
      conversation('hist', ['imported decision'], withSession: false);

      expect(ids(search.search('decision')), ['hist']);
    });
  });

  group('paging', () {
    setUp(() {
      for (var i = 0; i < 25; i++) {
        conversation('c$i', ['cache note $i']);
      }
    });

    test('pages are disjoint and cover every result', () {
      final seen = <String>[];
      String? cursor;
      var pages = 0;
      do {
        final page = search.search('cache', limit: 10, cursor: cursor);
        seen.addAll(ids(page));
        cursor = page.nextCursor;
        pages++;
      } while (cursor != null);

      expect(pages, 3);
      expect(seen, hasLength(25));
      expect(seen.toSet(), hasLength(25));
    });

    test('a write between pages rejects the stale cursor', () {
      final first = search.search('cache', limit: 10);
      conversation('late', ['cache written between pages']);

      expect(
        () => search.search('cache', limit: 10, cursor: first.nextCursor),
        throwsA(isA<StaleSearchCursor>()),
      );
      // And with no write in between the same cursor is served.
      final again = search.search('cache', limit: 10);
      expect(
        search.search('cache', limit: 10, cursor: again.nextCursor).hits,
        hasLength(10),
      );
    });

    test('a cursor is only good for the search that cut it', () {
      final first = search.search('cache', limit: 10);

      expect(
        () => search.search('note', limit: 10, cursor: first.nextCursor),
        throwsArgumentError,
      );
      expect(
        () => search.search('cache', cursor: 'not a cursor'),
        throwsArgumentError,
      );
    });
  });

  group('catching up', () {
    late Directory dir;
    late ConversationIndexer indexer;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('session_search_');
      indexer = ConversationIndexer(dao: dao, clock: clock);
      search = SessionSearchService(dao: dao, clock: clock, indexer: indexer);
    });
    tearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } on FileSystemException {
        // Windows keeps a handle on a file a failing test left open.
      }
    });

    String line(String text) =>
        '${jsonEncode({
          'type': 'user',
          'message': {'role': 'user', 'content': text},
        })}\n';

    test(
      'a search finds what a running session said since its last index',
      () async {
        final path = '${dir.path}/live.jsonl';
        File(path).writeAsStringSync(line('the morning plan'));
        SessionDao(db).insert(
          Session(
            id: 'live',
            repositoryId: 'r1',
            agentInstallationId: 'a1',
            title: 'Live',
            useWorktree: false,
            status: SessionStatus.running,
            createdAt: testTime,
            externalSessionId: 'conv-live',
          ),
        );
        await indexer.indexConversation(
          conversationId: 'conv-live',
          cli: AgentIds.claudeCode,
          filePath: path,
        );
        File(path).writeAsStringSync(
          line('the afternoon rollback'),
          mode: FileMode.append,
        );
        expect(search.search('rollback').hits, isEmpty);

        expect(await search.catchUp(), 1);

        expect(ids(search.search('rollback')), ['conv-live']);
        expect(indexer.appends, 1, reason: 'the append, not the file again');
      },
    );

    test('at most once an interval, and nothing polls', () async {
      final path = '${dir.path}/live.jsonl';
      File(path).writeAsStringSync(line('one'));
      SessionDao(db).insert(
        Session(
          id: 'live',
          repositoryId: 'r1',
          agentInstallationId: 'a1',
          title: 'Live',
          useWorktree: false,
          status: SessionStatus.running,
          createdAt: testTime,
          externalSessionId: 'conv-live',
        ),
      );
      await indexer.indexConversation(
        conversationId: 'conv-live',
        cli: AgentIds.claudeCode,
        filePath: path,
      );

      await search.catchUp();
      final looked = indexer.skips + indexer.appends + indexer.parses;
      await search.catchUp();
      expect(
        indexer.skips + indexer.appends + indexer.parses,
        looked,
        reason: 'the second, inside the interval, touched nothing',
      );

      clock.advance(const Duration(seconds: 11));
      await search.catchUp();
      expect(indexer.skips + indexer.appends + indexer.parses, looked + 1);
    });
  });
}
