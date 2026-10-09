import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_conversations/store.dart';
import 'package:karmashala_core/util.dart';
import 'package:karmashala_store/database.dart';
import 'package:sqlite3/sqlite3.dart' hide Session;
import 'package:test/test.dart';

class _FixedClock implements Clock {
  @override
  DateTime nowUtc() => DateTime.utc(2026, 10, 9, 12);
}

/// Counts the transactions it is asked to open.
class _CountingDatabase extends AppDatabase {
  _CountingDatabase() : super(sqlite3.openInMemory());

  int transactions = 0;

  @override
  T transaction<T>(T Function() action) {
    transactions++;
    return super.transaction(action);
  }
}

/// A large conversation's first reading is written a slice per transaction,
/// handing the server's event loop back between them, and ends as one
/// transaction would have left it.
void main() {
  late Directory dir;
  late _CountingDatabase db;
  late ConversationIndexDao dao;
  late ConversationIndexer indexer;
  const turns = kConversationWriteSlice * 2 + 5;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('conversation_slices_');
    db = _CountingDatabase();
    dao = ConversationIndexDao(db);
    indexer = ConversationIndexer(dao: dao, clock: _FixedClock());
  });
  tearDown(() {
    db.close();
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows keeps a handle on a file a failing test left open.
    }
  });

  String transcript(int count) {
    final path = '${dir.path}/c1.jsonl';
    File(path).writeAsStringSync(
      [
        for (var i = 0; i < count; i++)
          '${jsonEncode({
            'type': 'user',
            'message': {'role': 'user', 'content': 'turn number $i'},
          })}\n',
      ].join(),
    );
    return path;
  }

  Future<bool> index(String path) => indexer.indexConversation(
    conversationId: 'c1',
    cli: AgentIds.claudeCode,
    filePath: path,
  );

  int distinctOrdinals() =>
      db
              .query(
                'SELECT COUNT(DISTINCT ordinal) AS n FROM conversation_turns '
                "WHERE session_id = 'c1';",
              )
              .single['n']!
          as int;

  test('is written in slices and reads as one write would', () async {
    final path = transcript(turns);
    db.transactions = 0;

    expect(await index(path), isTrue);

    expect(db.transactions, 3);
    expect(dao.turnCountFor('c1'), turns);
    expect(distinctOrdinals(), turns);
    expect(dao.stateFor('c1')!.turns, turns);
    expect(dao.search('${turns - 1}').single.ordinal, turns - 1);

    // Its resume point was recorded: an append reads only the append.
    File(path).writeAsStringSync(
      '${jsonEncode({
        'type': 'user',
        'message': {'role': 'user', 'content': 'one more'},
      })}\n',
      mode: FileMode.append,
    );
    expect(await index(path), isTrue);
    expect(indexer.appends, 1);
    expect(dao.turnCountFor('c1'), turns + 1);
  });

  test('its state row is written last, so until then it is unread', () async {
    final path = transcript(turns);
    var done = false;
    final run = index(path).whenComplete(() => done = true);
    int? partly;
    ConversationIndexState? stateMeanwhile;
    while (!done) {
      final held = dao.turnCountFor('c1');
      if (held > 0 && held < turns) {
        partly = held;
        stateMeanwhile = dao.stateFor('c1');
      }
      await Future<void>.delayed(Duration.zero);
    }
    await run;

    expect(partly, isNotNull, reason: 'the loop never turned mid-write');
    expect(stateMeanwhile, isNull);
    expect(dao.stateFor('c1')!.turns, turns);
  });

  test('what an interrupted reading left is cleared, not doubled', () async {
    final path = transcript(turns);
    dao.addTurns(
      sessionId: 'c1',
      cli: AgentIds.claudeCode,
      turns: [
        for (var i = 0; i < 10; i++)
          ConversationTurn(ordinal: i, role: 'user', text: 'left over $i'),
      ],
    );

    expect(await index(path), isTrue);

    expect(dao.turnCountFor('c1'), turns);
    expect(dao.search('left over'), isEmpty);
  });

  test('two reads of one conversation at once write it once', () async {
    final path = transcript(turns);

    await Future.wait([index(path), index(path)]);

    expect(dao.turnCountFor('c1'), turns);
    expect(distinctOrdinals(), turns);
    expect(indexer.skips, 1);
  });

  test('an ACP session\'s large first reading from session_messages is '
      'written in slices too', () async {
    db.execute('PRAGMA foreign_keys = OFF;');
    const at = '2026-10-09T12:00:00Z';
    for (var i = 0; i < turns; i++) {
      db.execute(
        'INSERT INTO session_messages (id, session_id, ordinal, role, text, '
        'revision, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?);',
        ['m$i', 's1', i, i.isEven ? 'user' : 'agent', 'said $i', i, at, at],
      );
    }
    db.transactions = 0;

    expect(
      await indexer.indexConversation(
        conversationId: 'c1',
        cli: 'claude-acp',
        filePath: recordedConversationPath('s1'),
      ),
      isTrue,
    );

    expect(db.transactions, 3);
    expect(dao.turnCountFor('c1'), turns);
    expect(dao.stateFor('c1')!.filePath, recordedConversationPath('s1'));
    expect(dao.search('${turns - 1}').single.ordinal, turns - 1);
  });

  test('a conversation already indexed is still replaced in one', () async {
    final path = transcript(10);
    await index(path);
    // Rewritten from its first byte: read whole, and the old rows stay
    // searchable until the new ones replace them.
    File(path).writeAsStringSync(
      [
        for (var i = 0; i < turns; i++)
          '${jsonEncode({
            'type': 'user',
            'message': {'role': 'user', 'content': 'rewritten $i'},
          })}\n',
      ].join(),
    );
    db.transactions = 0;

    expect(await index(path), isTrue);

    expect(db.transactions, 1);
    expect(dao.turnCountFor('c1'), turns);
  });
}
