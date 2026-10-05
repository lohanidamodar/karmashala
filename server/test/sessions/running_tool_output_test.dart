import 'dart:convert';

import 'package:agent_cli/read.dart' show TranscriptMessage;
import 'package:karmashala_host/src/sessions/session_message_transcripts.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:test/test.dart';

/// A running call's output so far is shown while it runs, however the agent
/// sends it: a terminal it embeds, or text content (Codex's bridge streams
/// a command's output that way).
void main() {
  final at = DateTime.utc(2026, 10, 5);

  TranscriptMessage projected(Map<String, Object?> tool) =>
      SessionMessageTranscriptSource.project(
        SessionMessage(
          id: 't',
          sessionId: 's',
          role: SessionMessageRole.tool,
          toolJson: jsonEncode(tool),
          createdAt: at,
          updatedAt: at,
        ),
      );

  test('streamed text on a running command is its output so far', () {
    final row = projected({
      'toolCallId': 'c1',
      'title': 'ping localhost',
      'kind': 'execute',
      'status': 'in_progress',
      'content': [
        {
          'type': 'content',
          'content': {'type': 'text', 'text': 'Reply from 127.0.0.1'},
        },
      ],
    });

    expect(row.pendingToolUseId, 'c1');
    expect(row.tool!.output, 'Reply from 127.0.0.1');
  });

  test('a running edit\'s diff is not read as output', () {
    final row = projected({
      'toolCallId': 'c1',
      'kind': 'edit',
      'status': 'in_progress',
      'content': [
        {'type': 'diff', 'path': '/w/a.txt', 'oldText': 'a', 'newText': 'b'},
      ],
    });

    expect(row.tool!.output, isNull);
  });
}
