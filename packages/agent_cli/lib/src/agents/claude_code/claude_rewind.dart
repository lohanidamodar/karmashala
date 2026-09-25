import 'dart:convert';

import '../adapter/agent_rewind.dart';
import '../adapter/agent_rewind_points.dart';
import 'claude_code_descriptor.dart';

/// Claude Code's own undo: rewind points in its transcript, restored in its
/// pane with Esc twice or `/rewind`.
const OwnRewindPoints claudeRewind = OwnRewindPoints(
  lineMarker: '"file-history-snapshot"',
  parse: parseClaudeRewindPoints,
  note: claudeRewindNote,
);

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
    agentId: claudeCodeDescriptor.id,
    checkpoints: tracked.length,
    withFileEdits: tracked.values.where((v) => v).length,
    latest: latest,
  );
}

/// What Claude Code's own undo offers, said under the checkpoint list.
String claudeRewindNote(AgentRewindPoints? points) {
  final count = points?.checkpoints;
  final counted = count == null
      ? 'Claude Code also keeps its own rewind points for this '
            'conversation'
      : 'Claude Code also keeps $count rewind point'
            '${count == 1 ? '' : 's'} for this conversation'
            '${points!.withFileEdits == count ? '' : ', ${points.withFileEdits} with file edits'}';
  return '$counted. In its pane, press Esc twice or run /rewind to '
      'restore code and conversation together. It tracks only its own '
      'Edit and Write tools, not shell commands.';
}
