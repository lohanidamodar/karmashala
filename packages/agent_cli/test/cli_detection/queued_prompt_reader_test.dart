import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/src/agents/domain/agent_ids.dart';
import 'package:agent_cli/src/cli_detection/data/cli_transcript_reader.dart';
import 'package:test/test.dart';

import '../support/temp_directory.dart';

/// A prompt the person typed while Claude Code was working reaches the
/// transcript only as a `queued_command` attachment. Shapes are the recorded
/// ones; the text is made up.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('queued_test'));
  tearDown(() => removeTempDirectory(dir));

  Map<String, Object?> queued(Object prompt, {String? mode = 'prompt'}) => {
    'type': 'attachment',
    'attachment': {
      'type': 'queued_command',
      'prompt': prompt,
      'commandMode': mode,
    },
  };

  test('a prompt sent while working is the person\'s, marked so', () async {
    final file = File('${dir.path}/t.jsonl')
      ..writeAsStringSync(
        [
          queued('Also, what is 2+2?'),
          queued([
            {'type': 'text', 'text': 'And this one.'},
          ]),
          queued(
            '<task-notification><task-id>b1</task-id>'
            '<status>completed</status></task-notification>',
            mode: 'task-notification',
          ),
          queued(
            '<task-notification><task-id>b2</task-id></task-notification>',
            mode: null,
          ),
        ].map(jsonEncode).join('\n'),
      );

    final messages = await readCliTranscript(file.path, AgentIds.claudeCode);

    expect(messages.map((m) => '${m.role}:${m.text}:${m.queued}'), [
      'user:Also, what is 2+2?:true',
      'user:And this one.:true',
    ]);
    final wire = TranscriptMessage.fromJson(messages.first.toJson());
    expect(wire.queued, isTrue);
    expect(wire.queueState, QueuedState.sent);
  });

  /// Claude Code's own queue: `queue-operation` records, written the moment a
  /// mid-turn message enters it and again when it leaves.
  group('a message waiting in Claude Code\'s own queue', () {
    Map<String, Object?> op(String operation, {Object? content}) => {
      'type': 'queue-operation',
      'operation': operation,
      'timestamp': '2026-11-13T10:00:00.000Z',
      'sessionId': 's1',
      'content': ?content,
    };
    Map<String, Object?> user(String text) => {
      'type': 'user',
      'message': {'role': 'user', 'content': text},
    };

    Future<List<String>> read(List<Map<String, Object?>> lines) async {
      final file = File('${dir.path}/q.jsonl')
        ..writeAsStringSync(lines.map(jsonEncode).join('\n'));
      final messages = await readCliTranscript(file.path, AgentIds.claudeCode);
      return [for (final m in messages) '${m.queueState.name}:${m.text}'];
    }

    test('shows as waiting the moment it is queued', () async {
      final file = File('${dir.path}/q.jsonl')
        ..writeAsStringSync(
          jsonEncode(op('enqueue', content: 'Also check the logs')),
        );
      final messages = await readCliTranscript(file.path, AgentIds.claudeCode);
      expect(messages.single.role, 'user');
      expect(messages.single.text, 'Also check the logs');
      expect(messages.single.queueState, QueuedState.waiting);
      expect(messages.single.queued, isFalse);
      expect(messages.single.at, DateTime.utc(2026, 11, 13, 10));
      final wire = TranscriptMessage.fromJson(messages.single.toJson());
      expect(wire.queueState, QueuedState.waiting);
    });

    test('taken mid-turn, it is retired and told once as sent', () async {
      expect(
        await read([
          op('enqueue', content: 'Also check the logs'),
          op('remove', content: 'Also check the logs'),
          queued('Also check the logs'),
        ]),
        ['retired:Also check the logs', 'sent:Also check the logs'],
      );
    });

    test('taken as the next turn, it is retired for the user row', () async {
      expect(
        await read([
          op('enqueue', content: 'Next, the docs'),
          op('dequeue'),
          user('Next, the docs'),
        ]),
        ['retired:Next, the docs', 'none:Next, the docs'],
      );
    });

    test('a background run\'s notice, or no content, draws nothing', () async {
      expect(
        await read([
          op(
            'enqueue',
            content:
                '<task-notification><task-id>b1</task-id></task-notification>',
          ),
          op('enqueue'),
          op('dequeue'),
          op('dequeue'),
        ]),
        isEmpty,
      );
    });

    test('a dequeue retires in queue order, notices included', () async {
      expect(
        await read([
          op(
            'enqueue',
            content:
                '<task-notification><task-id>b1</task-id></task-notification>',
          ),
          op('enqueue', content: 'mine'),
          op('dequeue'),
        ]),
        ['waiting:mine'],
      );
    });

    test('search indexes the words once, at the row that sent them', () async {
      final file = File('${dir.path}/i.jsonl')
        ..writeAsStringSync(
          [
            op('enqueue', content: 'taken'),
            op('remove', content: 'taken'),
            queued('taken'),
            op('enqueue', content: 'still waiting'),
          ].map(jsonEncode).join('\n'),
        );
      final messages = await readCliTranscript(file.path, AgentIds.claudeCode);
      final turns = transcriptTurnsOf(messages, {'user', 'agent'});
      expect(turns.map((t) => '${t.ordinal}:${t.text}'), ['1:taken']);
    });

    test('a remove naming the second retires that one', () async {
      expect(
        await read([
          op('enqueue', content: 'first'),
          op('enqueue', content: 'second'),
          op('remove', content: 'second'),
        ]),
        ['waiting:first', 'retired:second'],
      );
    });

    test('pulled back into the prompt, every one is retired', () async {
      expect(
        await read([
          op('enqueue', content: 'first'),
          op('enqueue', content: 'second'),
          op('popAll'),
        ]),
        ['retired:first', 'retired:second'],
      );
    });

    test('reasoning before a reply is not spent on a queued row', () async {
      final lines = [
        {
          'type': 'assistant',
          'message': {
            'content': [
              {'type': 'thinking', 'thinking': 'Weighing it'},
            ],
          },
        },
        op('enqueue', content: 'meanwhile'),
        {
          'type': 'assistant',
          'message': {
            'content': [
              {'type': 'text', 'text': 'Done.'},
            ],
          },
        },
      ];
      final file = File('${dir.path}/t.jsonl')
        ..writeAsStringSync(lines.map(jsonEncode).join('\n'));
      final messages = await readCliTranscript(file.path, AgentIds.claudeCode);
      expect(messages.map((m) => m.text), ['meanwhile', 'Done.']);
      expect(messages.last.thinking, 'Weighing it');
    });
  });
}
