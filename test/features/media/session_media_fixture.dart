/// Transcript lines in the shapes the real stores write, for the media tests.
///
/// Every line here was copied from a Claude Code
/// `~/.claude/projects/{slug}/{id}.jsonl` and reduced: the keys are the ones
/// the scanner reads and nothing
/// has been invented. The pasted-image line in particular is the owner's own
/// case — *"where can i see this image preview in the terminal? i can't see
/// it"* — a picture put into the conversation by hand, which carries bytes and
/// no path at all.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// A real 1x1 PNG. The decoder is given an actual decodable file everywhere in
/// these tests, so only the degraded paths are simulated.
const String tinyPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhf'
    'DwAChwGA60e6kgAAAABJRU5ErkJggg==';

final Uint8List tinyPngBytes = base64Decode(tinyPngBase64);

/// A base64 payload of roughly [kilobytes] KB — how a pasted screenshot really
/// arrives. One measured in the owner's transcript was 638 KB.
String bulkyBase64(int kilobytes) {
  // Valid base64 of a repeated byte: not a decodable image, but the scanner
  // never decodes an image, it only moves bytes to disk. Size is the property
  // under test.
  final bytes = List<int>.filled(kilobytes * 1024, 0x41);
  return base64Encode(bytes);
}

/// A user turn that pasted a picture into the conversation.
String pastedImageLine({
  required String at,
  String? text,
  String data = tinyPngBase64,
  String mediaType = 'image/png',
}) => jsonEncode({
  'type': 'user',
  'timestamp': at,
  'message': {
    'role': 'user',
    'content': [
      if (text != null) {'type': 'text', 'text': text},
      {
        'type': 'image',
        'source': {'type': 'base64', 'media_type': mediaType, 'data': data},
      },
    ],
  },
});

/// The *other* shape a paste arrives in, copied from
/// `G--dev-godot-sampada-trails/e90749e9-…jsonl` line 383.
///
/// A picture put into a queued prompt is not a `user` line at all: its
/// top-level `type` is `attachment` and the blocks hang off
/// `attachment.prompt`. Eight of the nine pastes in that real transcript are
/// this shape, so a scanner that only reads `message.content` finds almost none
/// of them — which is the owner's complaint over again.
String queuedPasteLine({
  required String at,
  String? text,
  String data = tinyPngBase64,
  String mediaType = 'image/png',
}) => jsonEncode({
  'type': 'attachment',
  'timestamp': at,
  'attachment': {
    'type': 'queued_command',
    'prompt': [
      {
        'type': 'image',
        'source': {'type': 'base64', 'media_type': mediaType, 'data': data},
      },
      if (text != null) {'type': 'text', 'text': text},
    ],
    'commandMode': 'prompt',
  },
});

/// An assistant turn that called a tool.
String toolUseLine({
  required String at,
  required String id,
  required String name,
  required Map<String, Object?> input,
}) => jsonEncode({
  'type': 'assistant',
  'timestamp': at,
  'message': {
    'role': 'assistant',
    'content': [
      {'type': 'tool_use', 'id': id, 'name': name, 'input': input},
    ],
  },
});

/// The `user` line that answers a tool call. A tool that returns a picture —
/// `device_screenshot`, `browser_screenshot`, `browser_capture` — puts an
/// `image` block in here beside its text.
String toolResultLine({
  required String at,
  required String id,
  String? text,
  String? imageData,
  String mediaType = 'image/png',
}) => jsonEncode({
  'type': 'user',
  'timestamp': at,
  'message': {
    'role': 'user',
    'content': [
      {
        'type': 'tool_result',
        'tool_use_id': id,
        'content': [
          if (imageData != null)
            {
              'type': 'image',
              'source': {
                'type': 'base64',
                'media_type': mediaType,
                'data': imageData,
              },
            },
          if (text != null) {'type': 'text', 'text': text},
        ],
      },
    ],
  },
});

/// A plain conversational turn — the lines a transcript is mostly made of, and
/// the ones the scanner must be able to skip without decoding.
String textLine({
  required String at,
  required String role,
  required String text,
}) => jsonEncode({
  'type': role == 'user' ? 'user' : 'assistant',
  'timestamp': at,
  'message': {
    'role': role,
    'content': [
      {'type': 'text', 'text': text},
    ],
  },
});

/// Writes [lines] as a JSONL transcript and returns it.
File writeTranscript(Directory dir, String name, List<String> lines) =>
    File('${dir.path}/$name')..writeAsStringSync('${lines.join('\n')}\n');

/// Appends [lines] to an existing transcript, the way a live agent does.
void appendTranscript(File file, List<String> lines) =>
    file.writeAsStringSync('${lines.join('\n')}\n', mode: FileMode.append);
