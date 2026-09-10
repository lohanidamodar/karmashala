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

  /// Every conversation id one store holds, or `null` when the store told us
  /// nothing — the bulk sibling of [presenceOf], and the whole reason a
  /// housekeeping sweep is affordable.
  ///
  /// [presenceOf] is a question about *one* name and costs one listing, which
  /// is right before a resume. Asking it per row is not the same shape of cost:
  /// Codex's answer walks `sessions/` recursively, so N rows would be N walks
  /// of the same tree. This walks each tree **once** and hands back the set, so
  /// the cost is O(stores) whatever the number of rows.
  ///
  /// `null` rather than an empty set is load-bearing, and is the same
  /// distinction [ConversationPresence.unknown] draws: a store that is missing,
  /// unreachable, or in a format we cannot read has told us nothing, and an
  /// empty set would say "it holds no conversations at all" — which, used to
  /// decide what to delete, is every row at once.
  Future<Set<String>?> idsIn({
    required String storeHome,
    required AgentStoreFormat format,
  }) async {
    if (storeHome.isEmpty) return null;
    try {
      return switch (format) {
        AgentStoreFormat.claudeJsonl => await _claudeIds(storeHome),
        AgentStoreFormat.codexRollout => await _codexIds(storeHome),
        AgentStoreFormat.antigravityStore => await _antigravityIds(storeHome),
        AgentStoreFormat.none => null,
      };
    } on Object {
      // Threw part way through, so the set we have is a partial listing and a
      // partial listing is indistinguishable from a small store. Nothing.
      return null;
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

  /// `<home>/conversations/<id>.db` or `<home>/conversations/<id>.pb`.
  ///
  /// The cheapest of the three: Antigravity's conversation id **is** the file
  /// name, so this is one or two `stat`s and no listing at all. Nothing is
  /// opened — presence is a question about a name, and the file's contents are
  /// protobuf anyway.
  Future<ConversationPresence> _antigravity(String home, String id) async {
    final conversations = Directory(p.join(home, 'conversations'));
    if (!await conversations.exists()) return ConversationPresence.unknown;
    if (await File(p.join(conversations.path, '$id.db')).exists() ||
        await File(p.join(conversations.path, '$id.pb')).exists()) {
      return ConversationPresence.present;
    }
    return ConversationPresence.absent;
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

  /// The set form of [_claude]. Same paths, same lossy-encoding caveat: every
  /// project bucket is listed, because deriving the one this id would be in is
  /// the guess that comment refuses to make.
  Future<Set<String>?> _claudeIds(String home) async {
    final projects = Directory(p.join(home, 'projects'));
    if (!await projects.exists()) return null;
    final ids = <String>{};
    await for (final entity in projects.list()) {
      if (entity is! Directory) continue;
      await for (final file in entity.list()) {
        if (file is! File) continue;
        final name = p.basename(file.path);
        if (name.endsWith('.jsonl')) {
          ids.add(name.substring(0, name.length - '.jsonl'.length));
        }
      }
    }
    return ids;
  }

  /// The set form of [_antigravity]: the conversation id is the file name.
  Future<Set<String>?> _antigravityIds(String home) async {
    final conversations = Directory(p.join(home, 'conversations'));
    if (!await conversations.exists()) return null;
    final ids = <String>{};
    await for (final file in conversations.list()) {
      if (file is! File) continue;
      final name = p.basename(file.path);
      if (name.endsWith('.db')) {
        ids.add(name.substring(0, name.length - '.db'.length));
      } else if (name.endsWith('.pb')) {
        ids.add(name.substring(0, name.length - '.pb'.length));
      }
    }
    return ids;
  }

  /// The set form of [_codex]. The id is the tail of
  /// `rollout-<timestamp>-<id>.jsonl`, and the timestamp itself contains dashes
  /// — so the id is taken as the last five dash-separated fields (a UUID's
  /// shape) rather than by splitting on the first dash.
  Future<Set<String>?> _codexIds(String home) async {
    final sessions = Directory(p.join(home, 'sessions'));
    if (!await sessions.exists()) return null;
    final ids = <String>{};
    await for (final entity in sessions.list(recursive: true)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (!name.startsWith('rollout-') || !name.endsWith('.jsonl')) continue;
      final parts = name
          .substring('rollout-'.length, name.length - '.jsonl'.length)
          .split('-');
      if (parts.length < 5) continue;
      ids.add(parts.sublist(parts.length - 5).join('-'));
    }
    return ids;
  }
}
