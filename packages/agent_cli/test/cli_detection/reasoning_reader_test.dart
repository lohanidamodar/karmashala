import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/src/agents/domain/agent_ids.dart';
import 'package:agent_cli/src/cli_detection/data/cli_transcript_reader.dart';
import 'package:test/test.dart';

import '../support/temp_directory.dart';

/// The model's reasoning, as each CLI's terminal transcript records it:
/// Claude Code's `thinking` blocks and Codex's `reasoning` summaries. Shapes
/// are the recorded ones; the text is made up.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('reasoning_test'));
  tearDown(() => removeTempDirectory(dir));

  Future<List<TranscriptMessage>> read(
    String cli,
    List<Map<String, Object?>> records,
  ) {
    final file = File('${dir.path}/t.jsonl')
      ..writeAsStringSync(records.map(jsonEncode).join('\n'));
    return readCliTranscript(file.path, cli);
  }

  Map<String, Object?> assistant(List<Map<String, Object?>> content) => {
    'type': 'assistant',
    'message': {'id': 'msg_1', 'role': 'assistant', 'content': content},
  };

  Map<String, Object?> thinking(String text) => {
    'type': 'thinking',
    'thinking': text,
    'signature': 'c2lnbmF0dXJl',
  };

  group('Claude Code', () {
    test('a thinking block rides on the reply that follows it', () async {
      final messages = await read(AgentIds.claudeCode, [
        {
          'type': 'user',
          'message': {'role': 'user', 'content': 'is 91 prime?'},
        },
        assistant([thinking('Try small factors: 7 times 13.')]),
        assistant([
          {'type': 'text', 'text': 'No: 7 x 13.'},
        ]),
      ]);

      expect(messages.map((m) => '${m.role}:${m.text}'), [
        'user:is 91 prime?',
        'agent:No: 7 x 13.',
      ]);
      expect(messages.last.thinking, 'Try small factors: 7 times 13.');
    });

    test('an empty signed thinking block shows nothing', () async {
      final messages = await read(AgentIds.claudeCode, [
        assistant([thinking('')]),
        assistant([
          {'type': 'text', 'text': 'Done.'},
        ]),
      ]);

      expect(messages.single.text, 'Done.');
      expect(messages.single.thinking, isNull);
    });

    test('thinking before a call stays on the call once it answers', () async {
      final messages = await read(AgentIds.claudeCode, [
        assistant([thinking('List the tree first.')]),
        assistant([
          {
            'type': 'tool_use',
            'id': 'toolu_1',
            'name': 'Bash',
            'input': {'command': 'ls'},
          },
        ]),
        {
          'type': 'user',
          'message': {
            'role': 'user',
            'content': [
              {
                'type': 'tool_result',
                'tool_use_id': 'toolu_1',
                'content': 'a.txt',
              },
            ],
          },
        },
      ]);

      expect(messages.single.role, 'tool');
      expect(messages.single.tool?.output, 'a.txt');
      expect(messages.single.thinking, 'List the tree first.');
    });

    test('thinking is never hung on the person\'s next message', () async {
      final messages = await read(AgentIds.claudeCode, [
        assistant([thinking('Nothing more to say.')]),
        {
          'type': 'user',
          'message': {'role': 'user', 'content': 'next question'},
        },
      ]);

      expect(messages.single.role, 'user');
      expect(messages.single.thinking, isNull);
    });
  });

  group('Codex', () {
    Map<String, Object?> item(Map<String, Object?> payload) => {
      'timestamp': '2026-10-05T10:00:00.000Z',
      'type': 'response_item',
      'payload': payload,
    };

    Map<String, Object?> reasoning(List<String> summary) => item({
      'type': 'reasoning',
      'id': 'rs_1',
      'summary': [
        for (final text in summary) {'type': 'summary_text', 'text': text},
      ],
      'content': null,
      'encrypted_content': 'ZW5jcnlwdGVk',
    });

    test('a reasoning summary rides on the reply that follows it', () async {
      final messages = await read(AgentIds.codex, [
        reasoning(['**Checking factors**', 'Seven divides it.']),
        item({
          'type': 'message',
          'role': 'assistant',
          'content': [
            {'type': 'output_text', 'text': 'Not prime.'},
          ],
        }),
      ]);

      expect(messages.single.text, 'Not prime.');
      expect(
        messages.single.thinking,
        '**Checking factors**\n\nSeven divides it.',
      );
    });

    test('a reasoning record with no summary shows nothing', () async {
      final messages = await read(AgentIds.codex, [
        reasoning([]),
        item({
          'type': 'message',
          'role': 'assistant',
          'content': [
            {'type': 'output_text', 'text': 'Done.'},
          ],
        }),
      ]);

      expect(messages.single.thinking, isNull);
    });

    test('reasoning before a call stays on it once it answers', () async {
      final messages = await read(AgentIds.codex, [
        reasoning(['Look at the tree.']),
        item({
          'type': 'function_call',
          'name': 'shell_command',
          'arguments': '{"command":"ls"}',
          'call_id': 'call_1',
        }),
        item({
          'type': 'function_call_output',
          'call_id': 'call_1',
          'output': 'a.txt',
        }),
      ]);

      expect(messages.single.tool?.output, 'a.txt');
      expect(messages.single.thinking, 'Look at the tree.');
    });
  });
}
