import 'package:karmashala_host/src/acp/claude/claude_tools.dart';
import 'package:karmashala_host/src/acp/codex/codex_acp_mapping.dart';
import 'package:test/test.dart';

/// A chat session's web search shows its results as titles and links.
void main() {
  test('a Codex web search carries its results as a list', () {
    final call = codexToolCall({
      'type': 'webSearch',
      'id': 'ws1',
      'query': 'dart records',
      'action': {
        'type': 'search',
        'query': 'dart records',
        'queries': ['dart records'],
      },
      'results': [
        {
          'type': 'text_result',
          'title': 'Records',
          'url': 'https://dart.dev/records',
          'snippet': 'About records.',
        },
      ],
      'status': 'completed',
    }, cwd: '/w')!;

    expect(call['content'], [
      {
        'type': 'content',
        'content': {
          'type': 'text',
          'text': 'Records — https://dart.dev/records',
        },
      },
    ]);
  });

  test('Claude\'s WebSearch result is its links and summary', () {
    expect(
      ClaudeTools.resultTextOf(
        'Links: [{"title":"Records","url":"https://dart.dev/records"}]',
        {
          'query': 'dart records',
          'results': [
            {
              'tool_use_id': 'srvtoolu_1',
              'content': [
                {'title': 'Records', 'url': 'https://dart.dev/records'},
              ],
            },
            'Records bundle values.',
          ],
          'durationSeconds': 1.0,
          'searchCount': 1,
        },
      ),
      'Records — https://dart.dev/records\n\nRecords bundle values.',
    );
    expect(ClaudeTools.resultTextOf('plain', null), 'plain');
  });
}
