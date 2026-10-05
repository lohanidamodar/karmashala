import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/src/agents/domain/agent_ids.dart';
import 'package:agent_cli/src/cli_detection/data/cli_transcript_reader.dart';
import 'package:test/test.dart';

import '../support/temp_directory.dart';

/// A web search's results read as a list of titles and links. Shapes are the
/// recorded ones; the text is made up.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('web_search_test'));
  tearDown(() => removeTempDirectory(dir));

  Future<List<TranscriptMessage>> read(
    String cli,
    List<Map<String, Object?>> records,
  ) {
    final file = File('${dir.path}/t.jsonl')
      ..writeAsStringSync(records.map(jsonEncode).join('\n'));
    return readCliTranscript(file.path, cli);
  }

  test('Claude\'s WebSearch is its links and its summary, not JSON', () async {
    const links = [
      {'title': 'Records', 'url': 'https://dart.dev/records'},
      {'title': 'Patterns', 'url': 'https://dart.dev/patterns'},
    ];
    final messages = await read(AgentIds.claudeCode, [
      {
        'type': 'assistant',
        'message': {
          'content': [
            {
              'type': 'tool_use',
              'id': 't1',
              'name': 'WebSearch',
              'input': {'query': 'dart records'},
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
              'content':
                  'Web search results for query: "dart records"\n\n'
                  'Links: ${jsonEncode(links)}\n\nRecords bundle values.',
            },
          ],
        },
        'toolUseResult': {
          'query': 'dart records',
          'results': [
            {'tool_use_id': 'srvtoolu_1', 'content': links},
            'Records bundle values.',
          ],
          'durationSeconds': 2.5,
          'searchCount': 1,
        },
      },
    ]);

    final tool = messages.single.tool!;
    expect(tool.subject, 'dart records');
    expect(
      tool.output,
      'Records — https://dart.dev/records\n'
      'Patterns — https://dart.dev/patterns\n\n'
      'Records bundle values.',
    );
  });

  test('a Codex web search is a row naming what it searched', () async {
    Map<String, Object?> call(Map<String, Object?> action) => {
      'type': 'response_item',
      'payload': {
        'type': 'web_search_call',
        'status': 'completed',
        'action': action,
      },
    };
    final messages = await read(AgentIds.codex, [
      call({
        'type': 'search',
        'query': 'dart records',
        'queries': ['dart records'],
      }),
      call({'type': 'open_page', 'url': 'https://dart.dev/records'}),
    ]);

    expect(messages.map((m) => (m.tool?.name, m.tool?.subject)), [
      ('web_search', 'dart records'),
      ('web_search', 'https://dart.dev/records'),
    ]);
    expect(messages.every((m) => m.pendingToolUseId == null), isTrue);
  });
}
