import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/descriptors.dart' show AgentIds;
import 'package:karmashala_host/src/sessions/launch/session_handoffs.dart'
    show promptFilePointer;
import 'package:karmashala_host/src/sessions/session_transcripts.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A session whose agent was pointed at a file for its opening shows the
/// message itself as its first turn, not the pointer; a session from before
/// the handoff store, whose text is no longer held, shows what it said.
void main() {
  late Directory temp;
  late String record;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('pointer_transcript');
    record = p.join(temp.path, 'c.jsonl');
    final pointer = promptFilePointer(
      p.join(temp.path, 's1', 'message.md'),
      isPacket: false,
    );
    File(record).writeAsStringSync(
      [
        {
          'type': 'user',
          'timestamp': '2026-10-04T12:00:00Z',
          'message': {'role': 'user', 'content': pointer},
        },
        {
          'type': 'assistant',
          'timestamp': '2026-10-04T12:00:05Z',
          'message': {
            'content': [
              {'type': 'text', 'text': 'Done.'},
            ],
          },
        },
      ].map(jsonEncode).join('\n'),
    );
  });
  tearDown(() => temp.deleteSync(recursive: true));

  SessionTranscripts transcripts(String? Function(String) opening) =>
      SessionTranscripts(
        lookUp: (_) async =>
            (path: record, agentId: AgentIds.claudeCode, absence: null),
        openingBehindPointer: opening,
      );

  test('the opening held for the session replaces the pointer', () async {
    final rows = await transcripts(
      (id) => id == 's1' ? 'Fix the cart.\nThen the totals.' : null,
    ).messagesOf('s1');
    expect(rows.map((m) => (m.role, m.text)), [
      ('user', 'Fix the cart.\nThen the totals.'),
      ('agent', 'Done.'),
    ]);
  });

  test(
    'an older session, its text no longer held, shows the pointer',
    () async {
      final rows = await transcripts((_) => null).messagesOf('s1');
      expect(rows.first.text, startsWith('My opening message to you is in'));
    },
  );
}
