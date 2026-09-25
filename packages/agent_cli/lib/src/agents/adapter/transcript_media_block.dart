/// How a picture came to be in a conversation.
enum TranscriptMediaOrigin {
  /// A file the agent read, named by path.
  read,

  /// Pasted into a prompt.
  pasted,

  /// Returned by a tool.
  captured,
}

/// The tool calls a transcript has opened and not yet answered, carried from
/// one line to the next — and across incremental scans — so a result can be
/// matched to the call that asked for it.
class TranscriptMediaCalls {
  TranscriptMediaCalls({Map<String, String>? names, Set<String>? pathed})
    : names = {...?names},
      pathed = {...?pathed};

  /// Call id → tool name.
  final Map<String, String> names;

  /// Call ids whose picture was already taken from a path, so the same
  /// picture in their result is not listed twice.
  final Set<String> pathed;
}

/// A picture found on one transcript line, before it is resolved to something
/// drawable.
class TranscriptMediaBlock {
  TranscriptMediaBlock._({
    required this.origin,
    this.path,
    this.data,
    this.mediaType,
    this.tool,
  });

  /// A file on disk, in the agent's own environment.
  factory TranscriptMediaBlock.path(String path, {String? tool}) =>
      TranscriptMediaBlock._(
        origin: TranscriptMediaOrigin.read,
        path: path,
        tool: tool,
      );

  /// An Anthropic content block: `{type:'image', source:{type:'base64', …}}`,
  /// or the raw MCP shape `{type:'image', data, mimeType}` some records carry.
  factory TranscriptMediaBlock.bytes(
    Map<Object?, Object?> block,
    TranscriptMediaOrigin origin, {
    String? tool,
  }) {
    final source = block['source'];
    if (source is Map && source['type'] == 'base64') {
      return TranscriptMediaBlock._(
        origin: origin,
        data: source['data'] is String ? source['data'] as String : null,
        mediaType: source['media_type'] is String
            ? source['media_type'] as String
            : null,
        tool: tool,
      );
    }
    return TranscriptMediaBlock._(
      origin: origin,
      data: block['data'] is String ? block['data'] as String : null,
      mediaType: block['mimeType'] is String
          ? block['mimeType'] as String
          : null,
      tool: tool,
    );
  }

  /// Base64 bytes already in hand.
  factory TranscriptMediaBlock.inline(
    String mediaType,
    String data,
    TranscriptMediaOrigin origin,
  ) => TranscriptMediaBlock._(origin: origin, data: data, mediaType: mediaType);

  final TranscriptMediaOrigin origin;
  final String? path;
  final String? data;
  final String? mediaType;
  final String? tool;

  /// The `[Image #N]` id the CLI printed for a paste, when one was paired.
  int? pasteId;
}
