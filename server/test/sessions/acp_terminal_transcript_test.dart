import 'dart:convert';

import 'package:karmashala_host/src/sessions/session_message_transcripts.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:test/test.dart';

/// A tool call that embeds a terminal shows the command's output in the chat
/// — while it runs, and once it has ended — rather than the terminal's id.
void main() {
  final at = DateTime.utc(2026, 10, 4);

  SessionMessage row(Map<String, Object?> tool) => SessionMessage(
    id: 'm1',
    sessionId: 'acp',
    role: SessionMessageRole.tool,
    toolJson: jsonEncode(tool),
    createdAt: at,
    updatedAt: at,
  );

  Map<String, Object?> call(String status, Map<String, Object?> terminal) => {
    'toolCallId': 'c1',
    'title': 'npm test',
    'kind': 'execute',
    'status': status,
    'content': [
      {'type': 'terminal', 'terminalId': 'term-1', ...terminal},
    ],
  };

  test('a finished call shows what its terminal printed', () {
    final message = SessionMessageTranscriptSource.project(
      row(call('completed', {'output': 'ok 1\nok 2', 'exitCode': 0})),
    );
    expect(message.tool!.output, 'ok 1\nok 2');
    expect(message.pendingToolUseId, isNull);
  });

  test('a running call shows its output so far and is still pending', () {
    final message = SessionMessageTranscriptSource.project(
      row(call('in_progress', {'output': 'compiling…'})),
    );
    expect(message.tool!.output, 'compiling…');
    expect(message.pendingToolUseId, 'c1');
  });

  test('a running call with nothing printed yet has no output', () {
    final message = SessionMessageTranscriptSource.project(
      row(call('in_progress', const {})),
    );
    expect(message.tool!.output, isNull);
  });
}
