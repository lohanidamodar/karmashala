import 'dart:io';

import 'package:path/path.dart' as p;

import '../../cli_detection/data/store_session_reader.dart';
import '../../cli_detection/domain/conversation_presence.dart';
import '../../util/sqlite_rows.dart';
import '../adapter/agent_store.dart';
import '../adapter/agent_store_editor.dart';
import 'antigravity_store_editor.dart';
import 'antigravity_store_reader.dart';
import 'antigravity_store_sessions.dart';

/// Antigravity's store: `<home>/conversations/<id>.db` (or `.pb`) plus the
/// JSON, protobuf-text and SQLite side files beside it.
///
/// A store that yields *identity* without *content* — conversation id, working
/// directory, title, mtime — because the message payloads are protobuf in an
/// unpublished schema. So detection, adoption and the presence probe all work
/// for it, and no chat view is built from it.
class AntigravityStore implements AgentStore {
  const AntigravityStore();

  /// Step counts open one SQLite file per conversation and nothing in
  /// detection shows them, so the sweep stays a directory listing plus two
  /// small files.
  @override
  StoreSessionReader sessionReader({
    SqliteRowReader readRows = noSqliteBinding,
  }) => AntigravityStoreSessions(
    reader: AntigravityStoreReader(countSteps: false, readRows: readRows),
  );

  /// One directory listing; there is nothing to narrow.
  @override
  String? directoryNameFor(String workingDirectory) => null;

  /// The conversation id **is** the file name, so this is one or two `stat`s
  /// and no listing at all. Nothing is opened.
  @override
  Future<ConversationPresence> presenceOf(
    String storeHome,
    String conversationId,
  ) async {
    final conversations = Directory(p.join(storeHome, 'conversations'));
    if (!await conversations.exists()) return ConversationPresence.unknown;
    if (await File(p.join(conversations.path, '$conversationId.db')).exists() ||
        await File(p.join(conversations.path, '$conversationId.pb')).exists()) {
      return ConversationPresence.present;
    }
    return ConversationPresence.absent;
  }

  @override
  Future<Set<String>?> conversationIds(String storeHome) async {
    final conversations = Directory(p.join(storeHome, 'conversations'));
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

  /// The scan leaves out a conversation the store places in no directory — 38
  /// of the 44 with a transcript on the machine this was measured on — so its
  /// record is looked for by id.
  @override
  List<String> recordCandidates(String storeHome, String conversationId) => [
    for (final extension in const ['.db', '.pb'])
      p.join(storeHome, 'conversations', '$conversationId$extension'),
  ];

  @override
  AgentStoreEditor get editor => const AntigravityStoreEditor();
}
