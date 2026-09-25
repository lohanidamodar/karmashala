import 'dart:io';

import 'package:path/path.dart' as p;

import '../../cli_detection/data/store_session_reader.dart';
import '../../cli_detection/domain/conversation_presence.dart';
import '../../util/sqlite_rows.dart';
import '../adapter/agent_store.dart';
import '../adapter/agent_store_editor.dart';
import 'claude_code_store_editor.dart';
import 'claude_store_reader.dart';

/// Claude Code's store: `<home>/projects/<encoded cwd>/<id>.jsonl`.
class ClaudeCodeStore implements AgentStore {
  const ClaudeCodeStore();

  @override
  StoreSessionReader sessionReader({
    SqliteRowReader readRows = noSqliteBinding,
  }) => ClaudeStoreReader();

  /// The project directory is an encoding of the working directory, so a read
  /// can be narrowed to the directories that matter.
  @override
  String? directoryNameFor(String workingDirectory) =>
      claudeStoreDirectoryName(workingDirectory).toLowerCase();

  /// Every project directory is asked rather than the one the session's working
  /// directory would encode to: the directory name is a lossy dash-encoding, so
  /// deriving it is a guess, and a wrong guess here would call a live
  /// conversation missing.
  @override
  Future<ConversationPresence> presenceOf(
    String storeHome,
    String conversationId,
  ) async {
    final projects = Directory(p.join(storeHome, 'projects'));
    if (!await projects.exists()) return ConversationPresence.unknown;
    await for (final entity in projects.list()) {
      if (entity is! Directory) continue;
      if (await File(p.join(entity.path, '$conversationId.jsonl')).exists()) {
        return ConversationPresence.present;
      }
    }
    return ConversationPresence.absent;
  }

  /// The set form of [presenceOf]. Same paths, same lossy-encoding caveat:
  /// every project bucket is listed.
  @override
  Future<Set<String>?> conversationIds(String storeHome) async {
    final projects = Directory(p.join(storeHome, 'projects'));
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

  @override
  List<String> recordCandidates(String storeHome, String conversationId) =>
      const [];

  @override
  AgentStoreEditor get editor => const ClaudeCodeStoreEditor();
}
