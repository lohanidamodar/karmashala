import 'dart:io';

import 'package:path/path.dart' as p;

import '../../cli_detection/data/store_session_reader.dart';
import '../../cli_detection/domain/conversation_presence.dart';
import '../../util/sqlite_rows.dart';
import '../adapter/agent_store.dart';
import '../adapter/agent_store_editor.dart';
import 'codex_app_server_reader.dart';
import 'codex_store_editor.dart';
import 'codex_store_reader.dart';

/// Codex's store: `<home>/sessions/[YYYY/MM/DD/]rollout-<timestamp>-<id>.jsonl`,
/// read through `codex app-server`'s `thread/list` where it can be and by
/// walking the rollouts where it cannot.
class CodexStore implements AgentStore {
  const CodexStore();

  @override
  StoreSessionReader sessionReader({
    SqliteRowReader readRows = noSqliteBinding,
  }) => CodexAppServerReader(fallback: CodexStoreReader());

  /// Codex's layout is not addressable from a working directory.
  @override
  String? directoryNameFor(String workingDirectory) => null;

  @override
  Future<ConversationPresence> presenceOf(
    String storeHome,
    String conversationId,
  ) async {
    final sessions = Directory(p.join(storeHome, 'sessions'));
    if (!await sessions.exists()) return ConversationPresence.unknown;
    await for (final entity in sessions.list(recursive: true)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (name.startsWith('rollout-') &&
          name.endsWith('$conversationId.jsonl')) {
        return ConversationPresence.present;
      }
    }
    return ConversationPresence.absent;
  }

  /// The id is the tail of `rollout-<timestamp>-<id>.jsonl`, and the timestamp
  /// itself contains dashes — so the id is taken as the last five
  /// dash-separated fields (a UUID's shape) rather than by splitting on the
  /// first dash.
  @override
  Future<Set<String>?> conversationIds(String storeHome) async =>
      (await transcripts(storeHome))?.keys.toSet();

  @override
  Future<Map<String, String>?> transcripts(String storeHome) async {
    final sessions = Directory(p.join(storeHome, 'sessions'));
    if (!await sessions.exists()) return null;
    final found = <String, String>{};
    await for (final entity in sessions.list(recursive: true)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (!name.startsWith('rollout-') || !name.endsWith('.jsonl')) continue;
      final parts = name
          .substring('rollout-'.length, name.length - '.jsonl'.length)
          .split('-');
      if (parts.length < 5) continue;
      found[parts.sublist(parts.length - 5).join('-')] = entity.path;
    }
    return found;
  }

  @override
  List<String> recordCandidates(String storeHome, String conversationId) =>
      const [];

  @override
  AgentStoreEditor get editor => const CodexStoreEditor();
}
