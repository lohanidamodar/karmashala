import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/features/cli_detection/data/conversation_index_dao.dart';

void main() {
  late AppDatabase db;
  late ConversationIndexDao dao;

  setUp(() {
    db = AppDatabase.memory();
    dao = ConversationIndexDao(db);
  });
  tearDown(() => db.close());

  final at = DateTime.utc(2026, 9, 8, 10);

  void write(
    String sessionId,
    List<ConversationTurn> turns, {
    String cli = 'claudeCode',
    DateTime? modifiedAt,
    int? size,
  }) => dao.replaceTurns(
    sessionId: sessionId,
    cli: cli,
    filePath: 'C:/store/$sessionId.jsonl',
    turns: turns,
    indexedAt: at,
    modifiedAt: modifiedAt,
    size: size,
  );

  group('search', () {
    test('finds the turn that said it, and says which conversation', () {
      write('c1', const [
        ConversationTurn(
          ordinal: 4,
          role: 'user',
          text: 'we decided to copy the gitignored paths in',
        ),
      ]);

      final hits = dao.search('gitignored');
      expect(hits.single.sessionId, 'c1');
      expect(hits.single.ordinal, 4);
      expect(hits.single.role, 'user');
      expect(hits.single.excerpt, contains('gitignored'));
    });

    test('carries the age of the reading, not just the answer', () {
      write('c1', const [
        ConversationTurn(ordinal: 0, role: 'agent', text: 'the heap doubled'),
      ]);
      // A hit is only ever as current as the trigger that indexed it, so the
      // surface showing it has to be able to say how old that is.
      expect(dao.search('heap').single.indexedAt, at);
    });

    test('caps at fifty by default, and takes a smaller cap', () {
      write('c1', [
        for (var i = 0; i < 80; i++)
          ConversationTurn(ordinal: i, role: 'user', text: 'caching turn $i'),
      ]);

      expect(dao.search('caching'), hasLength(50));
      expect(dao.search('caching', limit: 5), hasLength(5));
    });

    test('a filename search finds the messages that discussed it', () {
      write('c1', const [
        ConversationTurn(
          ordinal: 0,
          role: 'user',
          text: 'the bug is in worktree_service.dart, near line 54',
        ),
      ]);

      expect(dao.search('worktree_service.dart'), hasLength(1));
      expect(dao.search('worktree_service'), hasLength(1));
    });

    test('a query the user is still typing already matches', () {
      write('c1', const [
        ConversationTurn(ordinal: 0, role: 'user', text: 'about worktrees'),
      ]);
      expect(dao.search('workt'), hasLength(1));
    });

    test('anything the user can type is a query, never an exception', () {
      write('c1', const [
        ConversationTurn(ordinal: 0, role: 'user', text: 'a plain sentence'),
      ]);
      // Each of these is FTS5 syntax. None of them may reach FTS5 as syntax.
      for (final query in const [
        'NEAR(',
        'a OR',
        '"unclosed',
        '^start',
        'col:value',
        '((()))',
        '*',
        r'a\b',
      ]) {
        expect(() => dao.search(query), returnsNormally, reason: query);
      }
    });

    test('one statement per search', () {
      write('c1', const [
        ConversationTurn(ordinal: 0, role: 'user', text: 'caching'),
      ]);
      dao.statements = 0;
      dao.search('caching');
      expect(dao.statements, 1);
    });

    test('a query too short to search costs no statement at all', () {
      dao.statements = 0;
      expect(dao.search('c'), isEmpty);
      expect(dao.statements, 0);
    });
  });

  group('replaceTurns', () {
    test('replaces one conversation and leaves the others alone', () {
      write('c1', const [
        ConversationTurn(ordinal: 0, role: 'user', text: 'caching first'),
      ]);
      write('c2', const [
        ConversationTurn(ordinal: 0, role: 'user', text: 'caching second'),
      ]);
      write('c1', const [
        ConversationTurn(ordinal: 0, role: 'user', text: 'heap instead'),
      ]);

      expect(dao.search('caching').map((h) => h.sessionId), ['c2']);
      expect(dao.search('heap').map((h) => h.sessionId), ['c1']);
      expect(dao.turnCountFor('c1'), 1);
    });

    test('batches the inserts rather than paying a statement a turn', () {
      dao.statements = 0;
      write('c1', [
        for (var i = 0; i < 300; i++)
          ConversationTurn(ordinal: i, role: 'user', text: 'turn $i'),
      ]);
      // One DELETE, ceil(300 / 128) INSERTs, one watermark.
      expect(dao.statements, 1 + 3 + 1);
    });

    test('an empty transcript costs a delete and a watermark, no insert', () {
      dao.statements = 0;
      write('c1', const []);
      expect(dao.statements, 2);
      expect(dao.turnCountFor('c1'), 0);
    });
  });

  group('the watermark', () {
    test('matches only when both the mtime and the size are the ones read', () {
      final modified = DateTime.utc(2026, 9, 8, 9);
      write(
        'c1',
        const [ConversationTurn(ordinal: 0, role: 'user', text: 'x')],
        modifiedAt: modified,
        size: 4096,
      );

      final state = dao.stateFor('c1')!;
      expect(state.matches(modifiedAt: modified, size: 4096), isTrue);
      expect(state.matches(modifiedAt: modified, size: 4097), isFalse);
      final later = modified.add(const Duration(seconds: 1));
      expect(state.matches(modifiedAt: later, size: 4096), isFalse);
    });

    test('a reading with no mtime can never be skipped on', () {
      write('c1', const [
        ConversationTurn(ordinal: 0, role: 'user', text: 'x'),
      ]);
      final state = dao.stateFor('c1')!;
      expect(state.modifiedAt, isNull);
      // An unknown is not a match. A transcript we could not stat is re-read.
      expect(state.matches(modifiedAt: DateTime.utc(2026), size: 1), isFalse);
    });

    test('keepTurns dates the reading without touching what is indexed', () {
      write('c1', const [
        ConversationTurn(ordinal: 0, role: 'user', text: 'the old answer'),
      ]);
      dao.keepTurns(
        sessionId: 'c1',
        cli: 'claudeCode',
        filePath: 'C:/store/c1.jsonl',
        turns: 1,
        indexedAt: at.add(const Duration(hours: 1)),
        modifiedAt: DateTime.utc(2026, 9, 8, 11),
        size: 99,
      );

      expect(dao.search('answer'), hasLength(1));
      expect(dao.stateFor('c1')!.size, 99);
    });
  });

  test('a conversation nothing has indexed has no state', () {
    expect(dao.stateFor('nope'), isNull);
    expect(dao.indexedConversationIds(), isEmpty);
  });
}
