import '../../sessions/tool_activity.dart';
import '../adapter/agent_media_reader.dart';
import '../adapter/transcript_media_block.dart';

/// The pictures on one Claude Code transcript line: a `tool_use` naming a file,
/// a paste (usually on `attachment.prompt`, not `message.content`), or a
/// `tool_result` image.
class ClaudeMediaReader implements AgentMediaReader {
  const ClaudeMediaReader();

  @override
  List<TranscriptMediaBlock> blocksIn(
    Map<Object?, Object?> json,
    TranscriptMediaCalls calls,
  ) {
    final blocks = <TranscriptMediaBlock>[];
    final message = json['message'];
    if (message is Map && message['content'] is List) {
      final before = blocks.length;
      _content(message['content']! as List, calls, blocks);
      _numberPastes(blocks, before, json['imagePasteIds']);
    }
    // A queued prompt is not a `user` line at all.
    final attachment = json['attachment'];
    if (attachment is Map) {
      final before = blocks.length;
      for (final key in const ['prompt', 'content']) {
        final list = attachment[key];
        if (list is! List) continue;
        for (final part in list) {
          if (part is Map && part['type'] == 'image') {
            blocks.add(
              TranscriptMediaBlock.bytes(part, TranscriptMediaOrigin.pasted),
            );
          }
        }
      }
      // The ids hang off the attachment on this shape, not off the record.
      _numberPastes(blocks, before, attachment['imagePasteIds']);
    }
    return blocks;
  }

  /// Gives pastes since [from] the `[Image #N]` ids the CLI printed, paired
  /// positionally and only on equal lengths — a wrong id opens a wrong picture.
  static void _numberPastes(
    List<TranscriptMediaBlock> blocks,
    int from,
    Object? raw,
  ) {
    if (raw is! List) return;
    final ids = [
      for (final id in raw)
        if (id is int) id,
    ];
    if (ids.length != raw.length) return;
    final pasted = [
      for (var i = from; i < blocks.length; i++)
        if (blocks[i].origin == TranscriptMediaOrigin.pasted) blocks[i],
    ];
    if (pasted.length != ids.length) return;
    for (var i = 0; i < ids.length; i++) {
      pasted[i].pasteId = ids[i];
    }
  }

  static void _content(
    List<Object?> content,
    TranscriptMediaCalls calls,
    List<TranscriptMediaBlock> blocks,
  ) {
    for (final part in content) {
      if (part is! Map) continue;
      switch (part['type']) {
        case 'tool_use':
          final name = part['name'];
          if (name is! String) continue;
          final path = toolActivityFor(name, part['input']).imagePath;
          final id = part['id'];
          if (id is String) {
            calls.names[id] = name;
            if (path != null) calls.pathed.add(id);
          }
          if (path != null) {
            blocks.add(TranscriptMediaBlock.path(path, tool: name));
          }
        case 'image':
          blocks.add(
            TranscriptMediaBlock.bytes(part, TranscriptMediaOrigin.pasted),
          );
        case 'tool_result':
          final id = part['tool_use_id'];
          final tool = id is String ? calls.names.remove(id) : null;
          // Claude answers `Read(shot.png)` with the file's bytes too, so the
          // same picture is in the transcript twice; the file on disk wins.
          if (id is String && calls.pathed.remove(id)) continue;
          final result = part['content'];
          if (result is! List) continue;
          for (final inner in result) {
            if (inner is Map && inner['type'] == 'image') {
              blocks.add(
                TranscriptMediaBlock.bytes(
                  inner,
                  TranscriptMediaOrigin.captured,
                  tool: tool,
                ),
              );
            }
          }
      }
    }
  }
}
