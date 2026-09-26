import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala_conversations/store.dart';
import 'package:karmashala_core/util.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' hide Session;

/// **What the index sees when a transcript carries the model's reasoning.**
///
/// `ConversationIndexer` takes `text` off the `kIndexedTranscriptRoles` rows and
/// never `TranscriptMessage.thinking`. That one rule is the whole gate, and it
/// is CLI-shaped nowhere: a Claude Code `thinking` content block, a Codex
/// `reasoning` payload and an Antigravity `thinking` field are each outside
/// `text`, so each is outside the index.
///
/// The invariant used to be written more strongly — that the reader never fills
/// `thinking` at all — and that half is gone, because it was a promise about the
/// parser rather than about the index and it kept Antigravity's reasoning off
/// screen. What must not move is what the index holds, so the Antigravity cases
/// below index the **same** transcript twice, once with the field and once with
/// it deleted, and compare rows, ordinals and statement counts rather than
/// asserting numbers written down by hand.
class _FixedClock implements Clock {
  _FixedClock(this.now);

  DateTime now;

  @override
  DateTime nowUtc() => now;
}

/// An [AppDatabase] that counts the statements it is asked to run.
///
/// The shape `conversation_indexer_test.dart` uses, for its reason: work is
/// counted, never timed.
class _CountingDatabase extends AppDatabase {
  _CountingDatabase() : super(sqlite3.openInMemory());

  int statements = 0;

  @override
  List<Map<String, Object?>> query(
    String sql, [
    List<Object?> params = const [],
  ]) {
    statements++;
    return super.query(sql, params);
  }

  @override
  void execute(String sql, [List<Object?> params = const []]) {
    statements++;
    super.execute(sql, params);
  }
}

/// One conversation's indexed rows, in transcript order.
typedef _Indexed = List<({int ordinal, String role, String text})>;

void main() {
  late Directory dir;
  late _CountingDatabase db;
  late ConversationIndexDao dao;
  late ConversationIndexer indexer;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('thinking_index_');
    db = _CountingDatabase();
    dao = ConversationIndexDao(db);
    indexer = ConversationIndexer(
      dao: dao,
      clock: _FixedClock(DateTime.utc(2026, 9, 9, 12)),
    );
  });
  tearDown(() {
    db.close();
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows keeps a handle on a file a failing test left open.
    }
  });

  String writeLines(String name, List<Map<String, Object?>> lines) {
    final path = p.join(dir.path, name);
    File(path).writeAsStringSync(lines.map(jsonEncode).join('\n'));
    return path;
  }

  /// An Antigravity conversation file, with its transcript where the CLI puts
  /// it — `brain/<id>/.system_generated/logs/transcript.jsonl`.
  String writeAntigravity(String id, List<Map<String, Object?>> lines) {
    final store = p.join(dir.path, '.gemini', 'antigravity-cli');
    final transcript = p.join(
      store,
      'brain',
      id,
      '.system_generated',
      'logs',
      'transcript.jsonl',
    );
    File(transcript).parent.createSync(recursive: true);
    File(transcript).writeAsStringSync(lines.map(jsonEncode).join('\n'));
    return p.join(store, 'conversations', '$id.db');
  }

  Future<void> index(String id, String cli, String path) =>
      indexer.indexConversation(conversationId: id, cli: cli, filePath: path);

  /// Everything the index holds for [id], oldest first.
  _Indexed indexed(String id) => [
    for (final row in db.query(
      'SELECT ordinal, role, text FROM conversation_turns '
      'WHERE session_id = ? ORDER BY ordinal;',
      [id],
    ))
      (
        ordinal: row['ordinal'] as int,
        role: row['role'] as String,
        text: row['text'] as String,
      ),
  ];

  group('the index reads text, and never thinking', () {
    test('a Claude Code thinking block is not indexed', () async {
      final path = writeLines('claude.jsonl', [
        {
          'type': 'assistant',
          'message': {
            'content': [
              {'type': 'thinking', 'thinking': 'perhaps blancmange instead'},
              {'type': 'text', 'text': 'the answer is a trifle'},
            ],
          },
        },
      ]);

      await index('c-claude', AgentIds.claudeCode, path);

      expect(dao.search('blancmange'), isEmpty);
      expect(dao.search('trifle'), hasLength(1));
    });

    test('a Codex reasoning payload is not indexed', () async {
      // The shape a real rollout writes here, `payload.type: reasoning` with a
      // `summary` of `summary_text` blocks — 6,491 of them in one store.
      final path = writeLines('codex.jsonl', [
        {
          'timestamp': '2026-09-09T10:00:00.000Z',
          'type': 'response_item',
          'payload': {
            'type': 'reasoning',
            'summary': [
              {'type': 'summary_text', 'text': 'weighing the syllabub'},
            ],
          },
        },
        {
          'timestamp': '2026-09-09T10:00:01.000Z',
          'type': 'response_item',
          'payload': {
            'type': 'message',
            'role': 'assistant',
            'content': [
              {'type': 'output_text', 'text': 'a posset, then'},
            ],
          },
        },
      ]);

      await index('c-codex', AgentIds.codex, path);

      expect(dao.search('syllabub'), isEmpty);
      expect(dao.search('posset'), hasLength(1));
    });

    test('an Antigravity thinking field is not indexed', () async {
      final path = writeAntigravity('with', _antigravityLines(thinking: true));

      await index('c-agy', AgentIds.antigravity, path);

      expect(dao.search('marzipan'), isEmpty, reason: 'the reasoning');
      expect(dao.search('nougat'), isEmpty, reason: 'and the other block');
      expect(dao.search('parkin'), hasLength(1), reason: 'the user said it');
      expect(dao.search('rendered'), hasLength(1), reason: 'the agent did');
    });

    test('and the rows it holds are the rows it held before', () async {
      // The claim the restatement rests on, proved rather than recorded: the
      // same transcript with and without the field indexes identically —
      // count, ordinals, roles and text — because nothing new is a row.
      final with_ = writeAntigravity('with', _antigravityLines(thinking: true));
      final without = writeAntigravity(
        'without',
        _antigravityLines(thinking: false),
      );

      await index('c-with', AgentIds.antigravity, with_);
      await index('c-without', AgentIds.antigravity, without);

      expect(indexed('c-with'), indexed('c-without'));
      expect(indexed('c-with').map((row) => row.ordinal), [
        0,
        2,
      ], reason: 'the user turn, then the agent turn two rows later');
      expect(dao.turnCountFor('c-with'), 2);
    });

    test('and costs the same statements', () async {
      final without = writeAntigravity(
        'without',
        _antigravityLines(thinking: false),
      );
      final before = db.statements;
      await index('c-without', AgentIds.antigravity, without);
      final plain = db.statements - before;

      final with_ = writeAntigravity('with', _antigravityLines(thinking: true));
      final middle = db.statements;
      await index('c-with', AgentIds.antigravity, with_);

      expect(db.statements - middle, plain);
    });

    test('a row that carries thinking is indexed by its text alone', () {
      // The rule with no CLI in it: whatever fills the field, the index takes
      // `text`. Asked of the filter the reader applies, with a row a parser
      // has already filled, so this cannot be satisfied by a parser that merely
      // declines to fill it.
      final turns = transcriptTurnsOf(const [
        TranscriptMessage(
          role: 'agent',
          text: 'the cake is done',
          thinking: 'frangipane, or almond paste',
        ),
      ], kIndexedTranscriptRoles);

      expect(turns.single.text, 'the cake is done');
      expect(turns.single.text, isNot(contains('frangipane')));
    });
  });
}

/// One Antigravity conversation, optionally with the reasoning the CLI wrote.
///
/// The shapes `_parseAntigravityLine` surveys: a user turn, a `PLANNER_RESPONSE`
/// whose only payload is a call, the `GENERIC` answering it, and a closing
/// `PLANNER_RESPONSE` that has text. 425 of the 435 thinking blocks on this
/// machine look like the second, which is why it is here at all.
List<Map<String, Object?>> _antigravityLines({required bool thinking}) => [
  {
    'step_index': 0,
    'source': 'USER_EXPLICIT',
    'type': 'USER_INPUT',
    'status': 'DONE',
    'created_at': '2026-09-09T10:00:00Z',
    'content': 'render the parkin chart',
  },
  {
    'step_index': 1,
    'source': 'MODEL',
    'type': 'PLANNER_RESPONSE',
    'status': 'DONE',
    'created_at': '2026-09-09T10:00:01Z',
    if (thinking) 'thinking': 'marzipan first, then the glaze',
    'tool_calls': [
      {
        'name': 'run_command',
        'args': {'CommandLine': '"chart --render"'},
      },
    ],
  },
  {
    'step_index': 2,
    'source': 'MODEL',
    'type': 'GENERIC',
    'status': 'DONE',
    'created_at': '2026-09-09T10:00:02Z',
    'content': 'exit code 0',
  },
  {
    'step_index': 3,
    'source': 'MODEL',
    'type': 'PLANNER_RESPONSE',
    'status': 'DONE',
    'created_at': '2026-09-09T10:00:03Z',
    if (thinking) 'thinking': 'nougat, in retrospect',
    'content': 'The chart is rendered.',
  },
];
