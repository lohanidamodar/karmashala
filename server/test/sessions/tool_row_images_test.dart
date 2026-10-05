import 'dart:convert';
import 'dart:io';

import 'package:karmashala_host/src/sessions/session_message_transcripts.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:test/test.dart';

/// A chat session's tool row draws the image its call answered with or
/// looked at, from a file: the row carries a path, never the bytes.
void main() {
  final at = DateTime.utc(2026, 10, 5, 9);
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('tool_row_images'));
  tearDown(() => dir.deleteSync(recursive: true));

  String? imageOf(Map<String, Object?> tool) =>
      SessionMessageTranscriptSource.project(
        SessionMessage(
          id: 't',
          sessionId: 's',
          role: SessionMessageRole.tool,
          toolJson: jsonEncode(tool),
          createdAt: at,
          updatedAt: at,
        ),
      ).tool?.imagePath;

  test('a resource link to an image file is drawn', () {
    final file = File('${dir.path}/shot.png')..writeAsBytesSync([1, 2, 3]);
    expect(
      imageOf({
        'toolCallId': 't1',
        'status': 'completed',
        'kind': 'other',
        'content': [
          {
            'type': 'content',
            'content': {
              'type': 'resource_link',
              'uri': file.uri.toString(),
              'name': 'shot.png',
              'mimeType': 'image/png',
            },
          },
        ],
      }),
      file.uri.toFilePath(),
    );
  });

  test('image content an agent sent inline is written to a file', () {
    final path = imageOf({
      'toolCallId': 't1',
      'status': 'completed',
      'kind': 'other',
      'content': [
        {
          'type': 'content',
          'content': {
            'type': 'image',
            'mimeType': 'image/png',
            'data': base64Encode([9, 8, 7]),
          },
        },
      ],
    });
    expect(path, endsWith('.png'));
    expect(File(path!).readAsBytesSync(), [9, 8, 7]);
  });

  test('a read of an image file draws it; an edit of one does not', () {
    Map<String, Object?> call(String kind) => {
      'toolCallId': 't1',
      'status': 'completed',
      'kind': kind,
      'locations': [
        {'path': 'C:/work/shot.png'},
      ],
    };
    expect(imageOf(call('read')), 'C:/work/shot.png');
    expect(imageOf(call('other')), 'C:/work/shot.png');
    expect(imageOf(call('edit')), isNull);
  });
}
