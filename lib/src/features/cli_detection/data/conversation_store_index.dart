import 'dart:io';

import 'package:path/path.dart' as p;

import '../../agents/domain/agent_descriptor.dart';
import '../domain/conversation_presence.dart';

/// Answers "does this store hold conversation X" without reading a transcript.
///
/// Deliberately separate from `ClaudeStoreReader`/`CodexStoreReader`, which
/// parse every file to build a list. Presence is a question about a *name*, and
/// both stores put the conversation id in the path — so this is a directory
/// listing and a `stat`, cheap enough to ask before every resume, where a full
/// scan would not be.
///
/// The format comes from [AgentStoreSpec.format], so an agent added tomorrow is
/// answered by the same rule as the two that ship today, and one whose layout
/// nobody has read yet answers [ConversationPresence.unknown] rather than
/// guessing.
class ConversationStoreIndex {
  const ConversationStoreIndex();

  Future<ConversationPresence> presenceOf({
    required String storeHome,
    required AgentStoreFormat format,
    required String conversationId,
  }) async {
    if (conversationId.isEmpty || storeHome.isEmpty) {
      return ConversationPresence.unknown;
    }
    try {
      return switch (format) {
        AgentStoreFormat.claudeJsonl => await _claude(
          storeHome,
          conversationId,
        ),
        AgentStoreFormat.codexRollout => await _codex(
          storeHome,
          conversationId,
        ),
        AgentStoreFormat.antigravityStore => await _antigravity(
          storeHome,
          conversationId,
        ),
        AgentStoreFormat.none => ConversationPresence.unknown,
      };
    } on Object {
      // A store that threw part way through told us nothing, and "nothing" is
      // not "absent" — see [ConversationPresence].
      return ConversationPresence.unknown;
    }
  }

  /// `<home>/projects/<encoded cwd>/<id>.jsonl`.
  ///
  /// Every project directory is asked rather than the one the session's working
  /// directory would encode to: the directory name is a lossy dash-encoding, so
  /// deriving it is a guess, and a wrong guess here would call a live
  /// conversation missing.
  Future<ConversationPresence> _claude(String home, String id) async {
    final projects = Directory(p.join(home, 'projects'));
    if (!await projects.exists()) return ConversationPresence.unknown;
    await for (final entity in projects.list()) {
      if (entity is! Directory) continue;
      if (await File(p.join(entity.path, '$id.jsonl')).exists()) {
        return ConversationPresence.present;
      }
    }
    return ConversationPresence.absent;
  }

  /// `<home>/conversations/<id>.db`.
  ///
  /// The cheapest of the three: Antigravity's conversation id **is** the file
  /// name, so this is one `stat` and no listing at all. Nothing is opened —
  /// presence is a question about a name, and the file's contents are protobuf
  /// anyway.
  Future<ConversationPresence> _antigravity(String home, String id) async {
    final conversations = Directory(p.join(home, 'conversations'));
    if (!await conversations.exists()) return ConversationPresence.unknown;
    return await File(p.join(conversations.path, '$id.db')).exists()
        ? ConversationPresence.present
        : ConversationPresence.absent;
  }

  /// `<home>/sessions/[YYYY/MM/DD/]rollout-<timestamp>-<id>.jsonl`.
  Future<ConversationPresence> _codex(String home, String id) async {
    final sessions = Directory(p.join(home, 'sessions'));
    if (!await sessions.exists()) return ConversationPresence.unknown;
    await for (final entity in sessions.list(recursive: true)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (name.startsWith('rollout-') && name.endsWith('$id.jsonl')) {
        return ConversationPresence.present;
      }
    }
    return ConversationPresence.absent;
  }
}
