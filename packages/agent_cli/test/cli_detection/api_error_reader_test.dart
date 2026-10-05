import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/src/agents/domain/agent_ids.dart';
import 'package:agent_cli/src/cli_detection/data/cli_transcript_reader.dart';
import 'package:test/test.dart';

import '../support/temp_directory.dart';

/// Claude Code writes a failed API call as a synthetic assistant message
/// flagged `isApiErrorMessage`: the CLI's error, not the model's words.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('api_error_test'));
  tearDown(() => removeTempDirectory(dir));

  test('an API error is an error row', () async {
    final file = File('${dir.path}/t.jsonl')
      ..writeAsStringSync(
        [
          {
            'type': 'assistant',
            'isApiErrorMessage': true,
            'message': {
              'id': 'synthetic-1',
              'model': '<synthetic>',
              'role': 'assistant',
              'stop_reason': 'stop_sequence',
              'content': [
                {'type': 'text', 'text': 'API Error: 529 Overloaded'},
              ],
            },
          },
          {
            'type': 'assistant',
            'message': {
              'content': [
                {'type': 'text', 'text': 'Back again.'},
              ],
            },
          },
        ].map(jsonEncode).join('\n'),
      );

    final messages = await readCliTranscript(file.path, AgentIds.claudeCode);

    expect(messages.map((m) => '${m.role}:${m.text}'), [
      'error:API Error: 529 Overloaded',
      'agent:Back again.',
    ]);
  });
}
