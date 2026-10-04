import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart';
import 'package:test/test.dart';

/// Claude Code wraps a paste in tags in its record; the person's message is
/// what was inside them.
void main() {
  test('the paste tags around a user turn are taken off', () async {
    final dir = Directory.systemTemp.createTempSync('pasted_content');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/t.jsonl');
    await file.writeAsString(
      jsonEncode({
        'type': 'user',
        'timestamp': '2026-10-04T10:00:00.000Z',
        'message': {
          'role': 'user',
          'content':
              'Please carry out this request: <pasted_content id="ab12">'
              'Probe the chat view.\nThen report.'
              '</pasted_content id="ab12">',
        },
      }),
    );

    final messages = await readCliTranscript(file.path, AgentIds.claudeCode);
    expect(
      messages.single.text,
      'Please carry out this request: Probe the chat view.\nThen report.',
    );
  });
}
