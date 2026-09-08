import 'dart:convert';
import 'dart:io';

import 'package:karmashala/src/features/agents/domain/agent_ids.dart';
import 'package:karmashala/src/features/cli_detection/data/cli_transcript_reader.dart';
import 'package:karmashala/src/features/sessions/presentation/chat_transcript.dart';
import 'package:karmashala/src/features/sessions/presentation/session_transcript_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// A compacted session, rendered once.
///
/// The shape below is a real boundary record's: `type: system` with
/// `subtype: compact_boundary`, `parentUuid: null`, a `logicalParentUuid`
/// naming the pre-compaction tail, and a `compactMetadata`. What follows it is
/// the summary, which the CLI writes as a **user** message.
void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('karmashala_compact_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  String write(List<Map<String, Object?>> lines) {
    final file = File(p.join(tmp.path, 'session.jsonl'));
    file.writeAsStringSync(lines.map(jsonEncode).join('\n'));
    return file.path;
  }

  Map<String, Object?> turn(String role, String text, String uuid) => {
    'parentUuid': null,
    'type': role == 'user' ? 'user' : 'assistant',
    'uuid': uuid,
    'timestamp': '2026-09-08T10:00:00.000Z',
    'message': {
      'role': role,
      'content': [
        {'type': 'text', 'text': text},
      ],
    },
  };

  Map<String, Object?> boundary({String trigger = 'auto'}) => {
    'parentUuid': null,
    'logicalParentUuid': 'u2',
    'isSidechain': false,
    'type': 'system',
    'subtype': 'compact_boundary',
    'content': 'Conversation compacted',
    'compactMetadata': {
      'trigger': trigger,
      'preTokens': 999969,
      'postTokens': 9293,
    },
  };

  Map<String, Object?> summary(String text) => {
    ...turn('user', text, 'sum'),
    'isCompactSummary': true,
    'isVisibleInTranscriptOnly': true,
  };

  group('readCliTranscript', () {
    test('keeps every row, and marks the summary with its boundary', () async {
      final path = write([
        turn('user', 'do the thing', 'u1'),
        turn('assistant', 'done', 'u2'),
        boundary(),
        summary('This session is being continued…'),
        turn('user', 'carry on', 'u3'),
      ]);

      final rows = await readCliTranscript(path, AgentIds.claudeCode);

      // The list the conversation index reads is untouched: same rows, same
      // order, same roles. Only the summary gained a mark.
      expect(rows.map((r) => r.text), [
        'do the thing',
        'done',
        'This session is being continued…',
        'carry on',
      ]);
      expect(rows[2].compaction?.trigger, 'auto');
      expect(rows.where((r) => r.compaction != null), hasLength(1));
    });

    test('a system line that is not a boundary marks nothing', () async {
      final path = write([
        turn('user', 'hi', 'u1'),
        {'type': 'system', 'subtype': 'agents_killed'},
        turn('assistant', 'ok', 'u2'),
      ]);

      final rows = await readCliTranscript(path, AgentIds.claudeCode);
      expect(rows.every((r) => r.compaction == null), isTrue);
    });

    test('an uncompacted transcript marks nothing at all', () async {
      final path = write([
        turn('user', 'hi', 'u1'),
        turn('assistant', 'ok', 'u2'),
      ]);
      final rows = await readCliTranscript(path, AgentIds.claudeCode);
      expect(rows.every((r) => r.compaction == null), isTrue);
    });
  });

  group('chatMessagesFromTranscript', () {
    test('the history behind the boundary is not drawn a second time', () {
      const messages = [
        TranscriptMessage(role: 'user', text: 'do the thing'),
        TranscriptMessage(role: 'agent', text: 'done'),
        TranscriptMessage(
          role: 'user',
          text: 'This session is being continued…',
          compaction: CompactionBoundary(trigger: 'auto'),
        ),
        TranscriptMessage(role: 'user', text: 'carry on'),
      ];

      final chat = chatMessagesFromTranscript(messages);

      expect(chat.first.role, kCompactionNoticeRole);
      expect(chat.first.text, contains('2 earlier messages'));
      expect(chat.first.text, contains('(auto)'));
      expect(chat.map((m) => m.text).skip(1), [
        'This session is being continued…',
        'carry on',
      ]);
      // The pre-compaction turns are gone from the *reading*, not from the
      // record — which is why the line says so.
      expect(chat.first.text, contains('search'));
    });

    test('only the last boundary counts, and it is the one drawn', () {
      const messages = [
        TranscriptMessage(role: 'user', text: 'one'),
        TranscriptMessage(
          role: 'user',
          text: 'first summary',
          compaction: CompactionBoundary(trigger: 'auto'),
        ),
        TranscriptMessage(role: 'agent', text: 'two'),
        TranscriptMessage(
          role: 'user',
          text: 'second summary',
          compaction: CompactionBoundary(trigger: 'manual'),
        ),
        TranscriptMessage(role: 'user', text: 'three'),
      ];

      final chat = chatMessagesFromTranscript(messages);

      expect(chat.first.text, contains('3 earlier messages'));
      expect(chat.first.text, contains('(manual)'));
      expect(chat.map((m) => m.text).skip(1), ['second summary', 'three']);
    });

    test('an uncompacted transcript is passed through untouched', () {
      const messages = [
        TranscriptMessage(role: 'user', text: 'hi'),
        TranscriptMessage(role: 'agent', text: 'hello'),
      ];
      final chat = chatMessagesFromTranscript(messages);
      expect(chat.map((m) => m.role), ['user', 'agent']);
      expect(chat.map((m) => m.text), ['hi', 'hello']);
    });

    test('a boundary with nothing before it draws no line', () {
      const messages = [
        TranscriptMessage(
          role: 'user',
          text: 'summary',
          compaction: CompactionBoundary(),
        ),
        TranscriptMessage(role: 'agent', text: 'on we go'),
      ];
      final chat = chatMessagesFromTranscript(messages);
      expect(chat.map((m) => m.role), ['user', 'agent']);
    });
  });

  testWidgets('the boundary is drawn as a marked row, not as a turn', (
    tester,
  ) async {
    const messages = [
      TranscriptMessage(role: 'user', text: 'do the thing'),
      TranscriptMessage(
        role: 'user',
        text: 'the summary of it',
        compaction: CompactionBoundary(trigger: 'auto'),
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatTranscriptView(
            messages: chatMessagesFromTranscript(messages),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('COMPACTED'), findsOneWidget);
    expect(find.textContaining('1 earlier message'), findsOneWidget);
    // The pre-compaction turn is not drawn again above it.
    expect(find.text('do the thing'), findsNothing);
  });
}
