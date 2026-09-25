import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import '../../cli_detection/domain/detected_session.dart';
import '../adapter/agent_store_editor.dart';

final _log = Logger('cli.sessionMutator');

/// Renames and removes Codex conversations the way Codex does: a rename is
/// *asked of Codex*, and a delete keeps `session_index.jsonl` in step.
class CodexStoreEditor implements AgentStoreEditor {
  const CodexStoreEditor();

  /// Asks Codex itself to name the thread. `session_index.jsonl` is a mirror
  /// Codex writes and never reads, so writing it there would be overwritten.
  /// With no server to ask, the rename is skipped, never faked.
  @override
  Future<void> rename(
    DetectedSession session,
    String title,
    StoreEditContext context,
  ) async {
    final client = context.serverFor?.call(
      session.environmentId,
      session.storeHome,
    );
    if (client == null) {
      _log.warning('No Codex to rename ${session.sessionId} in');
      return;
    }
    try {
      final failure = await client.rename(session.sessionId, title);
      if (failure != null) {
        _log.warning('Codex would not rename ${session.sessionId}: $failure');
      }
    } catch (error) {
      _log.warning(
        'Could not reach Codex to rename ${session.sessionId}',
        error,
      );
    }
  }

  /// Drops the index entries naming any of [conversationIds] — one read, one
  /// write.
  @override
  Future<void> prune(
    String storeHome,
    Set<String> conversationIds,
    StoreEditContext context,
  ) async {
    final counters = context.counters;
    final index = File(p.join(storeHome, 'session_index.jsonl'));
    if (!await index.exists()) return;
    counters.storeScans++;
    final lines = (await index.readAsString())
        .split('\n')
        .where((l) => l.trim().isNotEmpty)
        .toList();
    counters.indexEntriesRead += lines.length;
    final out = [
      for (final line in lines)
        if (!conversationIds.contains(_tryDecode(line)?['id'])) line,
    ];
    await index.writeAsString(out.isEmpty ? '' : '${out.join('\n')}\n');
    counters.indexWrites++;
  }

  Map<String, dynamic>? _tryDecode(String line) {
    try {
      final decoded = jsonDecode(line);
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    }
  }
}
