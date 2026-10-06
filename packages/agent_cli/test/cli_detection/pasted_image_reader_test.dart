import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/src/agents/domain/agent_ids.dart';
import 'package:agent_cli/src/cli_detection/data/cli_transcript_reader.dart';
import 'package:agent_cli/src/sessions/tool_images.dart';
import 'package:test/test.dart';

import '../support/temp_directory.dart';

/// An image the person pasted into a prompt is on their own row, written to
/// the tool-image cache, beside the "[Image #N]" the CLI put in the text.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('pasted_image_test'));
  tearDown(() => removeTempDirectory(dir));

  // Not a real picture: the cache neither decodes nor checks one.
  const bytes = [137, 80, 78, 71, 13, 10, 26, 10, 5, 6, 7, 8];
  final data = base64Encode(bytes);

  Future<List<TranscriptMessage>> read(
    String cli,
    List<Map<String, Object?>> records,
  ) {
    final file = File('${dir.path}/t.jsonl')
      ..writeAsStringSync(records.map(jsonEncode).join('\n'));
    return readCliTranscript(file.path, cli);
  }

  test('a Claude prompt with a pasted image carries it on its row', () async {
    final messages = await read(AgentIds.claudeCode, [
      {
        'type': 'user',
        'timestamp': '2026-10-06T09:00:00.000Z',
        'message': {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': '[Image #1] why is this cut off?'},
            {
              'type': 'image',
              'source': {
                'type': 'base64',
                'media_type': 'image/png',
                'data': data,
              },
            },
          ],
        },
        'imagePasteIds': [1],
      },
    ]);

    final row = messages.single;
    expect(row.role, 'user');
    expect(row.text, '[Image #1] why is this cut off?');
    expect(row.images, hasLength(1));
    expect(row.images.single, startsWith(toolImageDirectory.path));
    expect(File(row.images.single).readAsBytesSync(), bytes);
  });

  test('an image pasted with no words is still a row of its own', () async {
    final messages = await read(AgentIds.claudeCode, [
      {
        'type': 'user',
        'message': {
          'role': 'user',
          'content': [
            {
              'type': 'image',
              'source': {
                'type': 'base64',
                'media_type': 'image/png',
                'data': data,
              },
            },
          ],
        },
      },
    ]);
    expect(messages.single.role, 'user');
    expect(messages.single.images, hasLength(1));
  });

  test('a Codex prompt with a pasted image carries it, without the tags '
      'Codex wraps it in', () async {
    final messages = await read(AgentIds.codex, [
      {
        'timestamp': '2026-10-06T09:00:00.000Z',
        'type': 'response_item',
        'payload': {
          'type': 'message',
          'role': 'user',
          'content': [
            {
              'type': 'input_text',
              'text': '<image name=[Image #1] path="/tmp/clipboard-1.png">',
            },
            {
              'type': 'input_image',
              'image_url': 'data:image/png;base64,$data',
              'detail': 'high',
            },
            {'type': 'input_text', 'text': '</image>'},
            {'type': 'input_text', 'text': '[Image #1] see the overlap'},
          ],
        },
      },
    ]);

    final row = messages.single;
    expect(row.role, 'user');
    expect(row.text, '[Image #1] see the overlap');
    expect(row.images, hasLength(1));
    expect(File(row.images.single).readAsBytesSync(), bytes);
  });

  test('the images cross the wire', () {
    const row = TranscriptMessage(
      role: 'user',
      text: 'look',
      images: ['/cache/a.png', '/cache/b.png'],
    );
    expect(TranscriptMessage.fromJson(row.toJson()).images, row.images);
    expect(
      const TranscriptMessage(role: 'user', text: 'x').toJson(),
      isNot(contains('images')),
    );
  });
}
