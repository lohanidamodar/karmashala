import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/src/agents/domain/agent_ids.dart';
import 'package:agent_cli/src/cli_detection/data/cli_transcript_reader.dart';
import 'package:agent_cli/src/sessions/tool_images.dart';
import 'package:test/test.dart';

import '../support/temp_directory.dart';

/// An image a tool answered with — an MCP screenshot, a Codex `view_image` —
/// arrives as base64 in the result. It is written once to a cache file and
/// the row points at it, the way a `Read` of an image file does.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('tool_image_test'));
  tearDown(() => removeTempDirectory(dir));

  // Not a real picture: the cache neither decodes nor checks one.
  const bytes = [137, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3, 4];
  String data() => base64Encode(bytes);

  Future<List<TranscriptMessage>> read(
    String cli,
    List<Map<String, Object?>> records,
  ) {
    final file = File('${dir.path}/t.jsonl')
      ..writeAsStringSync(records.map(jsonEncode).join('\n'));
    return readCliTranscript(file.path, cli);
  }

  Map<String, Object?> claudeCall(
    String id,
    String name,
    Map<String, Object?> input,
  ) => {
    'type': 'assistant',
    'message': {
      'content': [
        {'type': 'tool_use', 'id': id, 'name': name, 'input': input},
      ],
    },
  };

  Map<String, Object?> claudeResult(String id, List<Object?> content) => {
    'type': 'user',
    'message': {
      'role': 'user',
      'content': [
        {'type': 'tool_result', 'tool_use_id': id, 'content': content},
      ],
    },
  };

  Map<String, Object?> image(String mediaType) => {
    'type': 'image',
    'source': {'type': 'base64', 'media_type': mediaType, 'data': data()},
  };

  test('an MCP screenshot is drawn from a file holding its bytes', () async {
    final messages = await read(AgentIds.claudeCode, [
      claudeCall('t1', 'mcp__device__screenshot', {}),
      claudeResult('t1', [
        {'type': 'text', 'text': 'Screenshot taken.'},
        image('image/png'),
      ]),
    ]);

    final tool = messages.single.tool!;
    expect(tool.output, 'Screenshot taken.');
    expect(tool.imagePath, endsWith('.png'));
    expect(File(tool.imagePath!).readAsBytesSync(), bytes);
  });

  test('a Read of an image keeps the file it read', () async {
    final messages = await read(AgentIds.claudeCode, [
      claudeCall('t1', 'Read', {'file_path': '/w/shot.png'}),
      claudeResult('t1', [image('image/png')]),
    ]);

    expect(messages.single.tool!.imagePath, '/w/shot.png');
  });

  test('a Codex call output carrying an image points at it', () async {
    final messages = await read(AgentIds.codex, [
      {
        'type': 'response_item',
        'payload': {
          'type': 'function_call',
          'name': 'view_image',
          'arguments': '{"path":"shot"}',
          'call_id': 'c1',
        },
      },
      {
        'type': 'response_item',
        'payload': {
          'type': 'function_call_output',
          'call_id': 'c1',
          'output': [
            {'type': 'input_text', 'text': 'viewed'},
            {
              'type': 'input_image',
              'image_url': 'data:image/jpeg;base64,${data()}',
            },
          ],
        },
      },
    ]);

    final tool = messages.single.tool!;
    expect(tool.output, 'viewed');
    expect(tool.imagePath, endsWith('.jpg'));
    expect(File(tool.imagePath!).readAsBytesSync(), bytes);
  });

  test('a Codex MCP call answering with an image points at it', () async {
    final messages = await read(AgentIds.codex, [
      {
        'type': 'event_msg',
        'payload': {
          'type': 'item_completed',
          'item': {
            'type': 'McpToolCall',
            'id': 'm1',
            'server': 'device',
            'tool': 'screenshot',
            'arguments': <String, Object?>{},
            'status': 'completed',
            'result': {
              'content': [
                {'type': 'image', 'data': data(), 'mimeType': 'image/webp'},
              ],
              'isError': false,
            },
          },
        },
      },
    ]);

    expect(messages.single.tool!.imagePath, endsWith('.webp'));
  });

  test('the same image is one file however often it is read', () {
    final first = spillToolImage(data(), mimeType: 'image/png');
    final again = spillToolImage(data(), mimeType: 'image/png');

    expect(first, isNotNull);
    expect(again, first);
    expect(spillToolImage('not base64 !!', mimeType: 'image/png'), isNull);
    expect(spillToolImage(data(), mimeType: 'image/tiff'), isNull);
  });
}
