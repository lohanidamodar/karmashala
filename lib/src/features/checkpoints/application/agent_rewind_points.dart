import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:riverpod/riverpod.dart';

import '../../agents/application/agent_providers.dart';
import '../../sessions/application/session_chat_source.dart';
import '../../sessions/application/session_providers.dart';

/// What an agent's own undo holds for a session, read from its transcript.
/// Read-only: restoring through it belongs to the agent, in its pane.
class AgentRewindPoints {
  const AgentRewindPoints({
    required this.agentId,
    required this.checkpoints,
    required this.withFileEdits,
    this.latest,
  });

  final String agentId;

  /// Prompts the agent can rewind to.
  final int checkpoints;

  /// Of those, the ones whose files it backed up — its "Restore code" rows.
  final int withFileEdits;

  final DateTime? latest;
}

/// Claude Code's rewind points, from the `file-history-snapshot` records in a
/// session transcript: one per prompt that started a turn, keyed by
/// `messageId`, its `snapshot.trackedFileBackups` naming the files backed up
/// under `~/.claude/file-history/<session>/`. Only keys are read, never the
/// backed-up contents; records that are not snapshots are skipped unparsed.
AgentRewindPoints parseClaudeRewindPoints(Iterable<String> lines) {
  final tracked = <String, bool>{};
  DateTime? latest;
  for (final line in lines) {
    if (!line.contains('"file-history-snapshot"')) continue;
    final Object? record;
    try {
      record = jsonDecode(line);
    } on FormatException {
      continue;
    }
    if (record is! Map || record['type'] != 'file-history-snapshot') continue;
    final id = record['messageId'];
    final snapshot = record['snapshot'];
    if (id is! String || snapshot is! Map) continue;
    final backups = snapshot['trackedFileBackups'];
    final hasFiles = backups is Map && backups.isNotEmpty;
    tracked[id] = (tracked[id] ?? false) || hasFiles;
    final at = DateTime.tryParse('${snapshot['timestamp']}');
    if (at != null && (latest == null || at.isAfter(latest))) latest = at;
  }
  return AgentRewindPoints(
    agentId: AgentIds.claudeCode,
    checkpoints: tracked.length,
    withFileEdits: tracked.values.where((v) => v).length,
    latest: latest,
  );
}

/// The agent's own rewind points for [sessionId], or `null` when its agent
/// keeps none this app can read. Read once per open panel: it scans the store.
final agentRewindPointsProvider = FutureProvider.autoDispose
    .family<AgentRewindPoints?, String>((ref, sessionId) async {
      final session = ref.read(sessionDaoProvider).getById(sessionId);
      final externalId = session?.externalSessionId;
      if (session == null || externalId == null || externalId.isEmpty) {
        return null;
      }
      final agentId = ref
          .read(agentInstallationDaoProvider)
          .getById(session.agentInstallationId)
          ?.agentId;
      if (agentId != AgentIds.claudeCode) return null;
      final path = await ref
          .read(sessionTranscriptLocatorProvider)
          .locate(agentId: agentId!, externalSessionId: externalId);
      if (path == null) return null;
      try {
        final lines = await File(path)
            .openRead()
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .where((line) => line.contains('"file-history-snapshot"'))
            .toList();
        return parseClaudeRewindPoints(lines);
      } on FileSystemException {
        return null;
      }
    });
