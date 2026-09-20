import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala_core/util.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/cli_detection/application/conversation_indexer.dart';
import 'package:karmashala/src/features/cli_detection/data/conversation_index_dao.dart';
import 'package:agent_cli/read.dart';
import 'package:agent_cli/process.dart';
import 'package:sqlite3/sqlite3.dart' hide Session;

/// A clock that only moves when a test moves it.
class _FixedClock implements Clock {
  _FixedClock(this.now);

  DateTime now;

  @override
  DateTime nowUtc() => now;
}

/// An [AppDatabase] that records every statement it is asked to run.
///
/// The same shape `store_slot_cost_test.dart` uses, and for the same reason:
/// `package:sqlite3` is synchronous and on the isolate that draws, so a
/// statement is frame time. Counted, never timed.
class _CountingDatabase extends AppDatabase {
  _CountingDatabase() : super(sqlite3.openInMemory());

  final List<String> statements = [];

  void reset() => statements.clear();

  @override
  List<Map<String, Object?>> query(
    String sql, [
    List<Object?> params = const [],
  ]) {
    statements.add(sql);
    return super.query(sql, params);
  }

  @override
  void execute(String sql, [List<Object?> params = const []]) {
    statements.add(sql);
    super.execute(sql, params);
  }
}

String _line(Map<String, Object?> json) => '${jsonEncode(json)}\n';

void main() {
  late Directory dir;
  late _CountingDatabase db;
  late ConversationIndexDao dao;
  late _FixedClock clock;
  late ConversationIndexer indexer;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('conversation_indexer_');
    db = _CountingDatabase();
    dao = ConversationIndexDao(db);
    clock = _FixedClock(DateTime.utc(2026, 9, 8, 12));
    indexer = ConversationIndexer(dao: dao, clock: clock);
  });
  tearDown(() {
    db.close();
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows keeps a handle on a file a failing test left open.
    }
  });

  String claudeTranscript(String name, List<String> lines) {
    final path = '${dir.path}/$name';
    File(path).writeAsStringSync(lines.join());
    return path;
  }

  Future<bool> index(String path, {String id = 'c1'}) =>
      indexer.indexConversation(
        conversationId: id,
        cli: AgentIds.claudeCode,
        filePath: path,
      );

  group('what is searchable', () {
    test('a user turn and an agent turn, and nothing else', () async {
      final path = claudeTranscript('c1.jsonl', [
        _line({
          'type': 'user',
          'message': {'role': 'user', 'content': 'should we memoise parsing'},
        }),
        _line({
          'type': 'assistant',
          'message': {
            'content': [
              {'type': 'text', 'text': 'yes, keyed on the transcript mtime'},
            ],
          },
        }),
      ]);

      await index(path);

      expect(dao.search('memoise').single.role, 'user');
      expect(dao.search('mtime').single.role, 'agent');
    });

    test('a tool call and its output are NOT searchable', () async {
      // The requirement, and the reason this beats grep: searching a filename
      // must return the messages that *discussed* it, not every run that
      // touched it. Both halves of a call are checked — the command line the
      // model wrote, and the bytes the tool answered with.
      final path = claudeTranscript('c1.jsonl', [
        _line({
          'type': 'assistant',
          'message': {
            'content': [
              {
                'type': 'tool_use',
                'id': 't1',
                'name': 'Bash',
                'input': {'command': 'grep -rn caramelise lib/'},
              },
            ],
          },
        }),
        _line({
          'type': 'user',
          'message': {
            'content': [
              {
                'type': 'tool_result',
                'tool_use_id': 't1',
                'content': 'lib/pudding.dart:3: caramelise the sugar',
              },
            ],
          },
        }),
      ]);

      await index(path);

      expect(dao.search('caramelise'), isEmpty);
      expect(dao.search('pudding.dart'), isEmpty);
      expect(dao.turnCountFor('c1'), 0);
    });

    test('a thinking block is NOT searchable', () async {
      // The model working, not anybody's decision. Two gates hold this:
      // `readCliTranscript` never emits a thinking block as a turn, and
      // `kIndexedTranscriptRoles` would exclude it if it ever did.
      final path = claudeTranscript('c1.jsonl', [
        _line({
          'type': 'assistant',
          'message': {
            'content': [
              {'type': 'thinking', 'thinking': 'perhaps blancmange instead'},
              {'type': 'text', 'text': 'the answer is a trifle'},
            ],
          },
        }),
      ]);

      await index(path);

      expect(dao.search('blancmange'), isEmpty);
      expect(dao.search('trifle'), hasLength(1));
    });

    test('the ordinal is the position in the parsed transcript', () async {
      final path = claudeTranscript('c1.jsonl', [
        _line({
          'type': 'user',
          'message': {'role': 'user', 'content': 'first'},
        }),
        _line({
          'type': 'assistant',
          'message': {
            'content': [
              {'type': 'tool_use', 'id': 't1', 'name': 'Bash'},
            ],
          },
        }),
        _line({
          'type': 'assistant',
          'message': {
            'content': [
              {'type': 'text', 'text': 'afterwards'},
            ],
          },
        }),
      ]);

      await index(path);

      // 2, not 1: the tool row is counted, so the number lines up with what the
      // chat view renders rather than with the rows the index happens to hold.
      expect(dao.search('afterwards').single.ordinal, 2);
    });

    test("Antigravity's store yields nothing, and does not throw", () async {
      final path = claudeTranscript('agy.db', ['not a transcript at all']);
      final wrote = await indexer.indexConversation(
        conversationId: 'c1',
        cli: AgentIds.antigravity,
        filePath: path,
      );
      expect(wrote, isTrue);
      expect(dao.turnCountFor('c1'), 0);
    });
  });

  group('cost', () {
    test('an idle indexer does nothing, and asks for no scan', () async {
      var scans = 0;
      expect(indexer.hasWork, isFalse);
      db.reset();

      expect(
        await indexer.drain(() async {
          scans++;
          return const [];
        }),
        0,
      );

      expect(scans, 0, reason: 'nothing wanted must not buy a store walk');
      expect(db.statements, isEmpty, reason: 'and no statement either');
      expect(indexer.parses, 0);
    });

    test('a transcript that has not moved costs one SELECT, no read', () async {
      final path = claudeTranscript('c1.jsonl', [
        _line({
          'type': 'user',
          'message': {'role': 'user', 'content': 'the decision'},
        }),
      ]);
      await index(path);

      db.reset();
      indexer.parses = 0;
      expect(await index(path), isFalse);

      expect(indexer.skips, 1);
      expect(indexer.parses, 0, reason: 'the watermark answered');
      expect(db.statements, hasLength(1));
      expect(db.statements.single, startsWith('SELECT'));
    });

    test('a transcript that grew is re-read, and the rows replace', () async {
      final first = _line({
        'type': 'user',
        'message': {'role': 'user', 'content': 'the first thing'},
      });
      final path = claudeTranscript('c1.jsonl', [first]);
      await index(path);

      File(path).writeAsStringSync(
        first +
            _line({
              'type': 'assistant',
              'message': {
                'content': [
                  {'type': 'text', 'text': 'the second thing'},
                ],
              },
            }),
      );
      expect(await index(path), isTrue);

      expect(dao.turnCountFor('c1'), 2);
      expect(dao.search('second'), hasLength(1));
    });

    test('a want is one map entry until it is drained', () async {
      final path = claudeTranscript('c1.jsonl', [
        _line({
          'type': 'user',
          'message': {'role': 'user', 'content': 'queued'},
        }),
      ]);
      db.reset();
      indexer.want('c1', cli: AgentIds.claudeCode, filePath: path);

      expect(db.statements, isEmpty, reason: 'wanting costs nothing');
      expect(indexer.hasWork, isTrue);

      var scans = 0;
      await indexer.drain(() async {
        scans++;
        return const [];
      });

      expect(scans, 0, reason: 'a want with its own path needs no scan');
      expect(dao.search('queued'), hasLength(1));
      expect(indexer.hasWork, isFalse, reason: 'and the queue is empty after');
    });

    test('a pathless want resolves from the scan already paid for', () async {
      final path = claudeTranscript('c1.jsonl', [
        _line({
          'type': 'user',
          'message': {'role': 'user', 'content': 'adopted just now'},
        }),
      ]);
      indexer.want('c1');

      var scans = 0;
      await indexer.drain(() async {
        scans++;
        return [
          DetectedSession(
            cli: AgentIds.claudeCode,
            sessionId: 'c1',
            cwd: const EnvironmentPath(environmentId: 'windows', path: r'C:\r'),
            filePath: path,
            storeHome: dir.path,
          ),
        ];
      });

      expect(scans, 1);
      expect(dao.search('adopted'), hasLength(1));
    });

    test('a want the store cannot name is dropped, not retried', () async {
      indexer.want('gone');

      var scans = 0;
      Future<List<DetectedSession>> scan() async {
        scans++;
        return const [];
      }

      await indexer.drain(scan);
      await indexer.drain(scan);

      // One scan, not two: keeping the want would make every later slot walk
      // the stores for a conversation they may never name.
      expect(scans, 1);
      expect(indexer.hasWork, isFalse);
    });
  });

  group('degrading the way the reader does', () {
    test('a transcript whose lines stop parsing yields fewer rows', () async {
      final path = claudeTranscript('c1.jsonl', [
        _line({
          'type': 'user',
          'message': {'role': 'user', 'content': 'still readable'},
        }),
        'a line from a format we do not know\n',
        '{"type":"user","message":{"content":\n',
        _line({
          'type': 'user',
          'message': {'role': 'user', 'content': 'also'},
        }),
      ]);

      await index(path);

      expect(dao.turnCountFor('c1'), 2);
      expect(dao.search('readable'), hasLength(1));
    });

    test('a transcript that stops parsing keeps yesterday rows', () async {
      final path = claudeTranscript('c1.jsonl', [
        _line({
          'type': 'user',
          'message': {'role': 'user', 'content': 'the old decision'},
        }),
      ]);
      await index(path);

      // The version bump this file exists for: the format changed and nothing
      // parses any more. Yesterday's rows are a better answer than none.
      File(path).writeAsStringSync('{"v":2,"turns":[{"kind":"say"}]}\n');
      clock.now = clock.now.add(const Duration(hours: 3));
      expect(await index(path), isFalse);

      expect(dao.search('decision'), hasLength(1));
      // And the reading is re-dated, so nothing re-parses it to learn the
      // same nothing.
      expect(dao.stateFor('c1')!.indexedAt, clock.now);
      indexer.parses = 0;
      await index(path);
      expect(indexer.parses, 0);
    });

    test('a transcript that is gone keeps its rows', () async {
      final path = claudeTranscript('c1.jsonl', [
        _line({
          'type': 'user',
          'message': {'role': 'user', 'content': 'the worktree decision'},
        }),
      ]);
      await index(path);
      File(path).deleteSync();

      expect(await index(path), isFalse);

      // §20: the stored path is state, whether it resolves is a measurement,
      // and a conversation does not leave the index because a measurement
      // failed today.
      expect(dao.search('worktree'), hasLength(1));
    });

    test('an unreadable transcript is an empty parse, not a throw', () async {
      indexer = ConversationIndexer(
        dao: dao,
        clock: clock,
        read: (path, cli) => Future.error(const FileSystemException('locked')),
      );

      expect(
        await indexer.indexConversation(
          conversationId: 'c1',
          cli: AgentIds.claudeCode,
          filePath: '${dir.path}/never.jsonl',
        ),
        isTrue,
      );
      expect(dao.turnCountFor('c1'), 0);
    });

    test('a stat that cannot answer leaves no watermark', () async {
      final path = claudeTranscript('c1.jsonl', [
        _line({
          'type': 'user',
          'message': {'role': 'user', 'content': 'unstattable'},
        }),
      ]);
      indexer = ConversationIndexer(
        dao: dao,
        clock: clock,
        stat: (_) async => (modifiedAt: null, size: null),
      );

      await index(path);
      await index(path);

      // Both passes read the file: an unknown watermark is not a match, so a
      // transcript we cannot measure is re-read rather than assumed unchanged.
      expect(indexer.parses, 2);
      expect(indexer.skips, 0);
      expect(dao.search('unstattable'), hasLength(1));
    });
  });
}
