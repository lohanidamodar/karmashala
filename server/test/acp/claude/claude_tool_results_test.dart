import 'dart:convert';

import 'package:karmashala_host/src/acp/claude/claude_tools.dart';
import 'package:karmashala_host/src/sessions/session_message_transcripts.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:test/test.dart';

/// How a Claude tool result reads in a chat session's tool row.
void main() {
  test('a ToolSearch says which tools it loaded', () {
    expect(
      ClaudeTools.resultText([
        {'type': 'tool_reference', 'tool_name': 'WebFetch'},
        {'type': 'tool_reference', 'tool_name': 'mcp__docs__read'},
      ]),
      'Loaded tools: WebFetch, mcp__docs__read',
    );
  });

  test('a TaskStop says what it stopped, not its JSON', () {
    expect(
      ClaudeTools.resultTextOf('{"message":"Stopped"}', {
        'message': 'Successfully stopped task: b1',
        'task_id': 'b1',
        'task_type': 'local_bash',
        'command': 'ping localhost',
      }),
      'Successfully stopped task: b1',
    );
  });

  test('a SendMessage row in a chat session names who and what about', () {
    final row = SessionMessageTranscriptSource.project(
      SessionMessage(
        id: 't',
        sessionId: 's',
        role: SessionMessageRole.tool,
        toolJson: jsonEncode({
          'toolCallId': 't1',
          'title': 'SendMessage',
          'kind': 'other',
          'status': 'completed',
          'rawInput': {
            'to': 'reviewer',
            'summary': 'Ready for review',
            'message': 'A long body',
          },
          '_meta': {
            'claudeCode': {'toolName': 'SendMessage'},
          },
        }),
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      ),
    );
    expect(row.tool!.subject, 'to reviewer: Ready for review');
  });
}
