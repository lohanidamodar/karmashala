import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/src/agents/domain/agent_ids.dart';
import 'package:agent_cli/src/cli_detection/data/cli_transcript_reader.dart';
import 'package:test/test.dart';

import '../support/temp_directory.dart';

/// A prompt the person typed while Claude Code was working reaches the
/// transcript only as a `queued_command` attachment. Shapes are the recorded
/// ones; the text is made up.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('queued_test'));
  tearDown(() => removeTempDirectory(dir));

  Map<String, Object?> queued(Object prompt, {String? mode = 'prompt'}) => {
    'type': 'attachment',
    'attachment': {
      'type': 'queued_command',
      'prompt': prompt,
      'commandMode': mode,
    },
  };

  test('a prompt sent while working is the person\'s, marked so', () async {
    final file = File('${dir.path}/t.jsonl')
      ..writeAsStringSync(
        [
          queued('Also, what is 2+2?'),
          queued([
            {'type': 'text', 'text': 'And this one.'},
          ]),
          queued(
            '<task-notification><task-id>b1</task-id>'
            '<status>completed</status></task-notification>',
            mode: 'task-notification',
          ),
          queued(
            '<task-notification><task-id>b2</task-id></task-notification>',
            mode: null,
          ),
        ].map(jsonEncode).join('\n'),
      );

    final messages = await readCliTranscript(file.path, AgentIds.claudeCode);

    expect(messages.map((m) => '${m.role}:${m.text}:${m.queued}'), [
      'user:Also, what is 2+2?:true',
      'user:And this one.:true',
    ]);
    final wire = TranscriptMessage.fromJson(messages.first.toJson());
    expect(wire.queued, isTrue);
  });
}
