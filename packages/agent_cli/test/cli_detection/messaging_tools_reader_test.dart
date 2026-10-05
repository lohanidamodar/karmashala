import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/src/agents/domain/agent_ids.dart';
import 'package:agent_cli/src/cli_detection/data/cli_transcript_reader.dart';
import 'package:test/test.dart';

import '../support/temp_directory.dart';

/// SendMessage and TaskStop read as what they did, not as their JSON.
/// Shapes are the recorded ones; the text is made up.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('messaging_test'));
  tearDown(() => removeTempDirectory(dir));

  Future<List<TranscriptMessage>> read(List<Map<String, Object?>> records) {
    final file = File('${dir.path}/t.jsonl')
      ..writeAsStringSync(records.map(jsonEncode).join('\n'));
    return readCliTranscript(file.path, AgentIds.claudeCode);
  }

  Map<String, Object?> call(String id, String name, Object input) => {
    'type': 'assistant',
    'message': {
      'content': [
        {'type': 'tool_use', 'id': id, 'name': name, 'input': input},
      ],
    },
  };

  Map<String, Object?> result(String id, Object content, Object tur) => {
    'type': 'user',
    'message': {
      'role': 'user',
      'content': [
        {'type': 'tool_result', 'tool_use_id': id, 'content': content},
      ],
    },
    'toolUseResult': tur,
  };

  test('SendMessage names who it went to and what about', () async {
    final messages = await read([
      call('t1', 'SendMessage', {
        'to': 'reviewer',
        'summary': 'Ready for review',
        'message': 'A long message body\nover several lines.',
      }),
      result(
        't1',
        [
          {
            'type': 'text',
            'text': '{"success":true,"message":"Message sent to reviewer"}',
          },
        ],
        {'success': true, 'message': 'Message sent to reviewer', 'pin': false},
      ),
    ]);

    final tool = messages.single.tool!;
    expect(tool.subject, 'to reviewer: Ready for review');
    expect(tool.output, 'Message sent to reviewer');
  });

  test('TaskStop names the task and says it stopped', () async {
    final messages = await read([
      call('t1', 'TaskStop', {'task_id': 'b1x2y3'}),
      result(
        't1',
        '{"message":"Successfully stopped task: b1x2y3","task_id":"b1x2y3",'
            '"task_type":"local_bash","command":"ping localhost"}',
        {
          'message': 'Successfully stopped task: b1x2y3',
          'task_id': 'b1x2y3',
          'task_type': 'local_bash',
          'command': 'ping localhost',
        },
      ),
    ]);

    final tool = messages.single.tool!;
    expect(tool.subject, 'b1x2y3');
    expect(tool.output, 'Successfully stopped task: b1x2y3');
  });
}
