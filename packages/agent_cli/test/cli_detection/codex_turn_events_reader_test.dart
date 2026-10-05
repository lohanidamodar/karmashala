import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/src/agents/domain/agent_ids.dart';
import 'package:agent_cli/src/cli_detection/data/cli_transcript_reader.dart';
import 'package:test/test.dart';

import '../support/temp_directory.dart';

/// What happened to a Codex turn besides its messages and calls: a failure,
/// an interruption, a compaction. Shapes are the recorded ones; the text is
/// made up.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('codex_events_test'));
  tearDown(() => removeTempDirectory(dir));

  Future<List<String>> read(List<Map<String, Object?>> records) async {
    final file = File('${dir.path}/rollout.jsonl')
      ..writeAsStringSync(records.map(jsonEncode).join('\n'));
    final messages = await readCliTranscript(file.path, AgentIds.codex);
    return [for (final m in messages) '${m.role}:${m.text}'];
  }

  Map<String, Object?> event(Map<String, Object?> payload) => {
    'timestamp': '2026-10-05T10:00:00.000Z',
    'type': 'event_msg',
    'payload': payload,
  };

  test('a turn that failed is an error in the chat', () async {
    expect(
      await read([
        event({
          'type': 'task_complete',
          'turn_id': 'tu',
          'last_agent_message': null,
          'error': {
            'message': 'You have hit your usage limit.',
            'codex_error_info': 'usage_limit_exceeded',
          },
          'started_at': 1,
          'completed_at': 2,
          'duration_ms': 1000,
        }),
        event({
          'type': 'task_complete',
          'turn_id': 'tu2',
          'last_agent_message': 'Done.',
        }),
      ]),
      ['error:You have hit your usage limit.'],
    );
  });

  test('an interrupted turn says so', () async {
    expect(
      await read([
        event({
          'type': 'turn_aborted',
          'turn_id': 'tu',
          'reason': 'interrupted',
          'started_at': 1,
          'completed_at': 2,
          'duration_ms': 1000,
        }),
      ]),
      ['notice:Interrupted by you'],
    );
  });

  test('a compaction is a note, once', () async {
    expect(
      await read([
        {
          'timestamp': '2026-10-05T10:00:00.000Z',
          'type': 'compacted',
          'payload': {
            'message': '',
            'replacement_history': [
              {
                'type': 'message',
                'role': 'user',
                'content': [
                  {'type': 'input_text', 'text': 'an earlier prompt'},
                ],
              },
            ],
          },
        },
        event({
          'type': 'item_completed',
          'item': {'type': 'ContextCompaction', 'id': 'item-1'},
        }),
      ]),
      ['notice:Codex compacted its context'],
    );
  });
}
