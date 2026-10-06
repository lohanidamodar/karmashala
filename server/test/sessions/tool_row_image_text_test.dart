import 'dart:convert';
import 'dart:io';

import 'package:karmashala_host/src/sessions/session_message_transcripts.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:test/test.dart';

/// A screenshot a tool answered with is drawn as a picture — never shown as
/// the base64 it travelled as.
void main() {
  final at = DateTime.utc(2026, 10, 6, 9);
  final png = base64Encode(List.generate(600, (i) => i % 256));

  ({String? image, String? output}) project(Map<String, Object?> tool) {
    final row = SessionMessageTranscriptSource.project(
      SessionMessage(
        id: 't',
        sessionId: 's',
        role: SessionMessageRole.tool,
        toolJson: jsonEncode(tool),
        createdAt: at,
        updatedAt: at,
      ),
    );
    return (image: row.tool?.imagePath, output: row.tool?.output);
  }

  test('an answer that is only a picture prints no raw output', () {
    final seen = project({
      'toolCallId': 't1',
      'status': 'completed',
      'kind': 'other',
      'content': [
        {
          'type': 'content',
          'content': {'type': 'image', 'mimeType': 'image/png', 'data': png},
        },
      ],
      'rawOutput': {
        'content': [
          {'type': 'image', 'mimeType': 'image/png', 'data': png},
        ],
      },
    });
    expect(seen.image, endsWith('.png'));
    expect(seen.output ?? '', isNot(contains(png.substring(0, 40))));
  });

  test('a picture only in the raw output is drawn, and its bytes are not '
      'printed', () {
    final seen = project({
      'toolCallId': 't1',
      'status': 'completed',
      'kind': 'other',
      'rawOutput': {
        'content': [
          {'type': 'text', 'text': 'Screenshot of compact (390x844).'},
          {'type': 'image', 'mimeType': 'image/png', 'data': png},
        ],
      },
    });
    expect(seen.image, endsWith('.png'));
    expect(File(seen.image!).existsSync(), isTrue);
    expect(seen.output, contains('Screenshot of compact'));
    expect(seen.output, isNot(contains(png.substring(0, 40))));
    expect(seen.output, contains('[image]'));
  });
}
