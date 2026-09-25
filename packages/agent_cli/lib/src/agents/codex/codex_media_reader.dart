import 'dart:convert';

import '../../sessions/tool_activity.dart';
import '../adapter/agent_media_reader.dart';
import '../adapter/transcript_media_block.dart';

/// The pictures in one Codex rollout line. Best effort: unverified against a
/// real store, so written to find nothing rather than to guess wrong.
class CodexMediaReader implements AgentMediaReader {
  const CodexMediaReader();

  @override
  List<TranscriptMediaBlock> blocksIn(
    Map<Object?, Object?> json,
    TranscriptMediaCalls calls,
  ) {
    final payload = json['payload'];
    if (payload is! Map) return const [];
    final blocks = <TranscriptMediaBlock>[];
    switch (payload['type']) {
      case 'message':
        final content = payload['content'];
        if (content is! List) return const [];
        for (final part in content) {
          if (part is! Map) continue;
          if (part['type'] != 'input_image' && part['type'] != 'image') {
            continue;
          }
          final url = part['image_url'] ?? part['url'];
          if (url is! String) continue;
          final data = _dataUri(url);
          if (data != null) {
            blocks.add(
              TranscriptMediaBlock.inline(
                data.$1,
                data.$2,
                TranscriptMediaOrigin.pasted,
              ),
            );
          } else if (looksLikeImagePath(url)) {
            blocks.add(TranscriptMediaBlock.path(url));
          }
        }
      case 'function_call':
      case 'custom_tool_call':
        final name = payload['name'];
        final arguments = payload['arguments'];
        if (arguments is! String) return const [];
        final Object? decoded;
        try {
          decoded = jsonDecode(arguments);
        } on FormatException {
          return const [];
        }
        final path = toolActivityFor(
          name is String ? name : 'tool',
          decoded,
        ).imagePath;
        if (path != null) {
          blocks.add(
            TranscriptMediaBlock.path(path, tool: name is String ? name : null),
          );
        }
    }
    return blocks;
  }

  static (String, String)? _dataUri(String value) {
    if (!value.startsWith('data:')) return null;
    final comma = value.indexOf(',');
    if (comma < 0) return null;
    final head = value.substring(5, comma);
    if (!head.endsWith(';base64')) return null;
    return (head.substring(0, head.length - 7), value.substring(comma + 1));
  }
}
