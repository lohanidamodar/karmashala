import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/src/agents/domain/agent_ids.dart';
import 'package:agent_cli/src/cli_detection/data/cli_transcript_reader.dart';
import 'package:test/test.dart';

import '../support/temp_directory.dart';

/// ToolSearch answers with `tool_reference` blocks naming the tools it
/// loaded, and no text at all.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('tool_search_test'));
  tearDown(() => removeTempDirectory(dir));

  test('a ToolSearch says which tools it loaded', () async {
    final file = File('${dir.path}/t.jsonl')
      ..writeAsStringSync(
        [
          {
            'type': 'assistant',
            'message': {
              'content': [
                {
                  'type': 'tool_use',
                  'id': 't1',
                  'name': 'ToolSearch',
                  'input': {'query': 'select:WebFetch', 'max_results': 5},
                },
              ],
            },
          },
          {
            'type': 'user',
            'message': {
              'role': 'user',
              'content': [
                {
                  'type': 'tool_result',
                  'tool_use_id': 't1',
                  'content': [
                    {'type': 'tool_reference', 'tool_name': 'WebFetch'},
                    {'type': 'tool_reference', 'tool_name': 'mcp__docs__read'},
                  ],
                },
              ],
            },
            'toolUseResult': {
              'matches': ['WebFetch', 'mcp__docs__read'],
              'query': 'select:WebFetch',
              'total_deferred_tools': 40,
            },
          },
        ].map(jsonEncode).join('\n'),
      );

    final messages = await readCliTranscript(file.path, AgentIds.claudeCode);

    expect(messages.single.tool!.subject, 'select:WebFetch');
    expect(
      messages.single.tool!.output,
      'Loaded tools: WebFetch, mcp__docs__read',
    );
  });
}
