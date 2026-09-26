import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala_conversations/store.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_environments/store.dart';
import 'package:karmashala_host/data.dart';
import 'package:karmashala_host/src/data/conversations_handler.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_store/database.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

String _user(String text) =>
    '${jsonEncode({
      'type': 'user',
      'timestamp': '2026-09-27T10:00:00Z',
      'message': {'role': 'user', 'content': text},
    })}\n';

String _agent(String text) =>
    '${jsonEncode({
      'type': 'assistant',
      'timestamp': '2026-09-27T10:00:01Z',
      'message': {
        'content': [
          {'type': 'text', 'text': text},
        ],
      },
    })}\n';

/// The conversation index at the server (slice 1f): searched through the
/// data API by every client, fed by the session rows and imported history
/// the server writes, caught up on request, and backfilled once per store —
/// reading transcripts through the agent adapters, in a temp HOME only.
void main() {
  late Directory home;
  late AppDatabase db;
  late DataService service;
  late DataSession app;
  final now = DateTime.utc(2026, 9, 27, 12);
  final here = localHostEnvironment(now);

  setUp(() {
    home = Directory.systemTemp.createTempSync('conv_home_');
    db = AppDatabase.memory();
    service = DataService(db, clock: () => now);
    app = service.open((_) {});
    const at = '2026-01-01T00:00:00.000Z';
    ExecutionEnvironmentDao(db).upsert(here);
    for (final (id, name) in [('p1', 'Demo'), ('p2', 'Other')]) {
      db.execute(
        'INSERT INTO projects '
        '(id, name, root_environment_id, root_path, created_at) '
        'VALUES (?, ?, ?, ?, ?);',
        [id, name, here.id, '/src/$id', at],
      );
    }
    for (final (id, project) in [('r1', 'p1'), ('r3', 'p2')]) {
      db.execute(
        'INSERT INTO repositories '
        '(id, project_id, name, environment_id, path, created_at) '
        'VALUES (?, ?, ?, ?, ?, ?);',
        [id, project, id, here.id, '/src/$id', at],
      );
    }
    db.execute(
      'INSERT INTO agent_installations '
      '(id, agent_kind, environment_id, executable_path, created_at) '
      "VALUES ('a1', 'claudeCode', ?, 'claude', ?);",
      [here.id, at],
    );
  });

  tearDown(() {
    service.conversations.close();
    db.close();
    try {
      home.deleteSync(recursive: true);
    } on FileSystemException {
      // A temp folder left behind costs nothing.
    }
  });

  Matcher refused(DataRefusalCode code, [String? words]) => throwsA(
    isA<DataRefused>()
        .having((r) => r.code, 'code', code)
        .having((r) => r.message, 'message', contains(words ?? '')),
  );

  Session row(String id, {String? conversation, String repositoryId = 'r1'}) =>
      Session(
        id: id,
        repositoryId: repositoryId,
        agentInstallationId: 'a1',
        title: 'Work $id',
        useWorktree: false,
        status: SessionStatus.created,
        createdAt: now,
        externalSessionId: conversation,
      );

  ImportedSession imported(
    String id,
    String conversation, {
    String cli = 'claudeCode',
    String repositoryId = 'r3',
    String filePath = 'f',
  }) => ImportedSession(
    id: id,
    repositoryId: repositoryId,
    cli: cli,
    externalId: conversation,
    environmentId: here.id,
    filePath: filePath,
    storeHome: 'h',
    isSubagent: false,
    preview: 'hi',
    createdAt: now,
  );

  ConversationIndexDao dao() => service.conversations.dao;

  void index(
    String conversation,
    List<String> said, {
    String cli = 'claudeCode',
  }) => dao().replaceTurns(
    sessionId: conversation,
    cli: cli,
    filePath: '/nowhere/$conversation.jsonl',
    turns: [
      for (var i = 0; i < said.length; i++)
        ConversationTurn(
          ordinal: i,
          role: i.isEven ? 'user' : 'agent',
          text: said[i],
        ),
    ],
    indexedAt: now,
  );

  /// A Claude Code transcript in the temp HOME's store.
  File transcript(String conversation, String content) =>
      File(
          p.join(
            home.path,
            '.claude',
            'projects',
            '-src-r1',
            '$conversation.jsonl',
          ),
        )
        ..createSync(recursive: true)
        ..writeAsStringSync(content);

  TranscriptStores stores({DateTime Function()? clock}) => TranscriptStores(
    locator: CliStoreLocator(
      runnerFor: (_) => const LocalCommandRunner(),
      environment: {'HOME': home.path, 'USERPROFILE': home.path},
    ),
    environments: () => [here],
    clock: clock,
  );

  List<String> found(String query, {SessionSearchFilter? filter}) => [
    for (final hit
        in app
            .handle(
              ConversationsSearch(
                query,
                filter: filter ?? const SessionSearchFilter(),
              ),
            )
            .value
            .hits)
      hit.sessionId,
  ];

  group('search', () {
    setUp(() {
      app.handle(SessionCreate(row('s1', conversation: 'c1')));
      app.handle(SessionCreate(row('s2', conversation: 'c2')));
      app.handle(ImportedAdd(imported('i3', 'c3', cli: 'codex')));
      index('c1', ['the rate limiter drops bursts', 'yes, the rate limiter']);
      index('c2', ['we talked about the rate of change']);
      index('c3', ['codex also saw the rate limiter'], cli: 'codex');
      // Said, but nothing names it any more: not a result.
      index('gone', ['the rate limiter, deleted']);
    });

    test('answers a ranked page, one hit per conversation that can open', () {
      final page = app.handle(const ConversationsSearch('rate limiter')).value;
      expect({for (final h in page.hits) h.sessionId}, {'c1', 'c3'});
      final c1 = page.hits.firstWhere((h) => h.sessionId == 'c1');
      expect(c1.matches, 2);
      expect(c1.tier, ConversationMatchTier.phrase);
      expect(c1.excerpt, contains('rate limiter'));
      expect(c1.indexedAt, now);
      expect(page.generation, dao().generation);
      // No word of it anywhere else: the looser tiers answer only then.
      expect(found('rate'), containsAll(['c1', 'c2', 'c3']));
    });

    test('the same through the JSON envelope', () {
      final answer =
          app.handleJson({
                'id': 5,
                'kind': 'conversations.search',
                'arguments': {'query': 'rate limiter', 'limit': 1},
              })
              as Map<String, Object?>;
      expect(answer['id'], 5);
      final result = (answer['result']! as Map).cast<String, Object?>();
      expect(result['hits'] as List, hasLength(1));
      expect(result['nextCursor'], isA<String>());
    });

    test('a filter narrows: agent, conversation, project', () {
      expect(
        found('rate limiter', filter: const SessionSearchFilter(cli: 'codex')),
        ['c3'],
      );
      expect(
        found('rate', filter: const SessionSearchFilter(conversationId: 'c2')),
        ['c2'],
      );
      expect(
        found('rate', filter: const SessionSearchFilter(projectId: 'p2')),
        ['c3'],
      );
      expect(
        found('rate', filter: const SessionSearchFilter(repositoryId: 'r1')),
        unorderedEquals(['c1', 'c2']),
      );
    });

    test('pages follow a cursor; a write between pages refuses it', () {
      final first = app
          .handle(const ConversationsSearch('rate', limit: 1))
          .value;
      expect(first.hits, hasLength(1));
      final cursor = first.nextCursor!;
      final second = app
          .handle(ConversationsSearch('rate', limit: 1, cursor: cursor))
          .value;
      expect(second.hits.single.sessionId, isNot(first.hits.single.sessionId));

      expect(
        () => app.handle(
          ConversationsSearch('limiter', limit: 1, cursor: cursor),
        ),
        refused(DataRefusalCode.invalid, 'different query'),
      );
      expect(
        () => app.handle(
          const ConversationsSearch('rate', limit: 1, cursor: 'garbage'),
        ),
        refused(DataRefusalCode.invalid),
      );

      index('c2', ['the rate moved on']);
      expect(
        () => app.handle(ConversationsSearch('rate', limit: 1, cursor: cursor)),
        refused(DataRefusalCode.invalid, 'changed'),
      );
    });

    test('turns and status', () {
      final turns = app.handle(const ConversationsTurns('c1')).value;
      expect(
        [for (final t in turns) (t.ordinal, t.role)],
        [(0, 'user'), (1, 'agent')],
      );
      expect(
        app.handle(const ConversationsTurns('c1', from: 1)).value.single.text,
        'yes, the rate limiter',
      );
      expect(
        app.handle(const ConversationsTurns('c1', limit: 1)).value,
        hasLength(1),
      );
      expect(app.handle(const ConversationsTurns('nobody')).value, isEmpty);

      final status = app.handle(const ConversationsStatus()).value;
      expect(status.conversations, 4);
      expect(status.turns, 5);
      expect(status.generation, dao().generation);
      expect(status.backfilledAt, isNull);
      expect(status.backfilling, isFalse);
      expect(status.queued, 0);
    });

    test('a search writes nothing and tells nothing', () {
      final told = <DataChanges>[];
      service.open(told.add).handle(const DataSubscribe());
      final before = service.revision;
      app.handle(const ConversationsSearch('rate'));
      expect(service.revision, before);
      expect(told, isEmpty);
    });
  });

  group('catch-up', () {
    test('is answered later, never by the synchronous path', () async {
      expect(
        () => app.handle(const ConversationsCatchUp()),
        refused(DataRefusalCode.invalid, 'asynchronously'),
      );
      expect(DataSession.isAnsweredLater(const ConversationsCatchUp()), isTrue);
      expect(DataSession.isAnsweredLater(const ConversationsStatus()), isFalse);
      // Nothing started: nothing to read.
      expect((await app.handleLater(const ConversationsCatchUp())).value, 0);
      final answer = app.handleJson({
        'id': 9,
        'kind': 'conversations.catchUp',
        'arguments': <String, Object?>{},
      });
      expect(answer, isA<Future<Map<String, Object?>>>());
      final later = await (answer as Future<Map<String, Object?>>);
      expect(later['id'], 9);
      expect(later['result'], 0);
      // Every other request is answered at once through handleLater too.
      expect(
        (await app.handleLater(const ConversationsStatus())).value.turns,
        0,
      );
    });

    test('reads what a running session appended since', () async {
      final file = transcript('c1', _user('first question') + _agent('answer'));
      service.conversations.start(
        stores(),
        drainAfter: const Duration(hours: 1),
      );
      app.handle(SessionCreate(row('s1', conversation: 'c1')));
      expect(await service.conversations.drain(), 1);

      file.writeAsStringSync(_user('a zebra appears'), mode: FileMode.append);
      expect(found('zebra'), isEmpty);
      final answer =
          await (app.handleJson({
                'id': 3,
                'kind': 'conversations.catchUp',
                'arguments': <String, Object?>{},
              })
              as Future<Map<String, Object?>>);
      expect(answer['result'], 1);
      expect(found('zebra'), ['c1']);
      // At most once in a while, however often asked.
      file.writeAsStringSync(_user('a yak too'), mode: FileMode.append);
      expect((await app.handleLater(const ConversationsCatchUp())).value, 0);
    });
  });

  group('feeding', () {
    test('before start, nothing a row names is queued', () {
      transcript('c1', _user('hello there'));
      app.handle(SessionCreate(row('s1', conversation: 'c1')));
      app.handle(ImportedAdd(imported('i1', 'c9')));
      expect(service.conversations.indexer.wantedIds, isEmpty);
    });

    test('a created or edited row, and an imported record, are read', () async {
      final file = transcript('c1', _user('the heap doubled') + _agent('ok'));
      service.conversations.start(
        stores(),
        drainAfter: const Duration(hours: 1),
      );

      app.handle(SessionCreate(row('s1', conversation: 'c1')));
      app.handle(SessionCreate(row('s2')));
      expect(service.conversations.indexer.wantedIds, ['c1']);
      expect(await service.conversations.drain(), 1);
      expect(found('heap'), ['c1']);
      expect(dao().stateFor('c1')!.filePath, file.path);

      // A rename is the CLI's evidence that the transcript moved.
      file.writeAsStringSync(_user('then a leak'), mode: FileMode.append);
      app.handle(SessionEdit('s1', SessionPatch.rename('Leak', byUser: false)));
      expect(await service.conversations.drain(), 1);
      expect(found('leak'), ['c1']);

      // An imported record carries its own transcript, wherever it is.
      final elsewhere = File(p.join(home.path, 'elsewhere', 'c7.jsonl'))
        ..createSync(recursive: true)
        ..writeAsStringSync(_user('imported walrus'));
      app.handle(ImportedAdd(imported('i7', 'c7', filePath: elsewhere.path)));
      expect(await service.conversations.drain(), 1);
      expect(found('walrus'), ['c7']);
      expect(app.handle(const ConversationsStatus()).value.conversations, 2);
    });

    test(
      'a conversation its store does not hold is dropped, not kept',
      () async {
        service.conversations.start(
          stores(),
          drainAfter: const Duration(hours: 1),
        );
        app.handle(SessionCreate(row('s1', conversation: 'ghost')));
        expect(await service.conversations.drain(), 0);
        expect(service.conversations.indexer.wantedIds, isEmpty);
        expect(dao().stateFor('ghost'), isNull);
      },
    );

    test(
      'the server\'s own writes feed it too, drained on its timer',
      () async {
        transcript('c1', _user('announced otter'));
        app.handle(SessionCreate(row('s1', conversation: 'c1')));
        service.conversations.start(
          stores(),
          drainAfter: const Duration(milliseconds: 10),
        );
        service.announceSessions(['s1']);
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (found('otter').isEmpty && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(found('otter'), ['c1']);
      },
    );
  });

  group('backfill', () {
    test('reads the live and imported conversations once per store', () async {
      transcript('c1', _user('live penguin'));
      final other = File(p.join(home.path, 'x', 'c2.jsonl'))
        ..createSync(recursive: true)
        ..writeAsStringSync(_user('imported penguin'));
      app.handle(SessionCreate(row('s1', conversation: 'c1')));
      app.handle(ImportedAdd(imported('i2', 'c2', filePath: other.path)));

      // Nothing to read with: no stores yet.
      expect(await service.conversations.backfill(), 0);
      expect(dao().backfilledAt, isNull);

      final walked = stores();
      service.conversations.start(walked, drainAfter: const Duration(hours: 1));
      expect(await service.conversations.backfill(), 2);
      expect(walked.walks, 1);
      expect(found('penguin'), unorderedEquals(['c1', 'c2']));
      final stamped = app.handle(const ConversationsStatus()).value;
      expect(stamped.backfilledAt, now);
      expect(stamped.backfilling, isFalse);

      // The stamp is in the store: a later server reads nothing again.
      final again = DataService(db, clock: () => now);
      again.conversations.start(stores(), drainAfter: const Duration(hours: 1));
      expect(await again.conversations.backfill(), 0);
      again.conversations.close();
    });

    test('its stamp and the index counter are not preferences', () {
      for (final key in [
        kConversationIndexBackfilledAtKey,
        kConversationIndexGenerationKey,
      ]) {
        expect(
          () => app.handle(PreferenceSet(key, 'x')),
          refused(DataRefusalCode.reserved),
        );
      }
      index('c1', ['anything']);
      dao().markBackfilled(now);
      final prefs = app.handle(const PreferencesGet()).value;
      expect(prefs.keys, isNot(contains(kConversationIndexBackfilledAtKey)));
      expect(prefs.keys, isNot(contains(kConversationIndexGenerationKey)));
    });
  });

  group('transcript stores', () {
    test(
      'find each agent\'s transcripts by id, one walk while fresh',
      () async {
        final claude = transcript('c1', _user('x'));
        const id = '0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b';
        final rollout = File(
          p.join(
            home.path,
            '.codex',
            'sessions',
            '2026',
            '09',
            '27',
            'rollout-2026-09-27T10-00-00-$id.jsonl',
          ),
        )..createSync(recursive: true);
        var clock = now;
        final walked = stores(clock: () => clock);

        expect(await walked.locate('claudeCode', 'c1'), claude.path);
        expect(await walked.locate('codex', id), rollout.path);
        expect(await walked.locate('codex', 'c1'), isNull);
        expect(await walked.locate('claudeCode', 'nobody'), isNull);
        expect(walked.walks, 1);

        final later = transcript('c2', _user('y'));
        expect(await walked.locate('claudeCode', 'c2'), isNull);
        clock = clock.add(walked.fresh);
        expect(await walked.locate('claudeCode', 'c2'), later.path);
        expect(walked.walks, 2);
      },
    );

    test('no home is no store, not a failure', () async {
      final none = TranscriptStores(
        locator: CliStoreLocator(
          runnerFor: (_) => const LocalCommandRunner(),
          environment: const {},
        ),
        environments: () => [here],
      );
      expect(await none.all(), isEmpty);
    });
  });
}
