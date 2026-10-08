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
  conversation: claudeConversationRewind,
);

const _cutEvidence =
    'claude 2.1.287, read off the binary 2026-10-08: "--resume-session-at '
    '<message id>  When resuming, only messages up to and including the chain '
    'entry with <message.id> (use with --resume in print mode)". Live the same '
    "day: a resume at turn 1's last entry forgot turn 2 under the same session "
    'id, and a cut with nothing sent after it did not hold on the next resume';

/// Claude Code's conversation cut: `--resume-session-at` in chat form, its
/// `/rewind` menu in a terminal.
const ConversationRewind claudeConversationRewind = ConversationRewind(
  promptsOf: claudeConversationPrompts,
  chatEvidence: _cutEvidence,
  menu: RewindMenu(
    command: '/rewind',
    listMarker: 'Restore the code and/or conversation to a previous point',
    labels: {
      RewindMode.both: 'Restore code and conversation',
      RewindMode.conversation: 'Restore conversation',
      RewindMode.code: 'Restore code',
    },
    cancel: 'Never mind',
    evidence:
        'claude 2.1.287 binary, read 2026-10-08: the message selector titled '
        '"Restore the code and/or conversation to a previous point", then '
        '"Restore code and conversation", "Restore conversation", "Restore '
        'code" (the code ones only for a message that changed files), '
        '"Summarize from here", "Summarize up to here", "Never mind"',
  ),
);

/// The person's prompts on the live chain of a Claude Code transcript, oldest
/// first: from [leaf], else the newest main-thread entry, back along
/// `parentUuid`. Tool results, meta lines, compaction summaries and subagent
/// lines are not prompts; a compaction ends the walk, so nothing before it is
/// offered.
List<ConversationPrompt> claudeConversationPrompts(
  Iterable<String> lines, {
  String? leaf,
}) {
  final entries = <String, Map<Object?, Object?>>{};
  String? newest;
  for (final line in lines) {
    if (!line.contains('"uuid"')) continue;
    final Object? record;
    try {
      record = jsonDecode(line);
    } on FormatException {
      continue;
    }
    if (record is! Map) continue;
    final uuid = record['uuid'];
    if (uuid is! String || record['isSidechain'] == true) continue;
    entries[uuid] = record;
    if (record['type'] == 'user' || record['type'] == 'assistant') {
      newest = uuid;
    }
  }
  final prompts = <ConversationPrompt>[];
  final seen = <String>{};
  var at = leaf ?? newest;
  while (at != null && seen.add(at)) {
    final entry = entries[at];
    if (entry == null) break;
    final parent = entry['parentUuid'];
    final text = _promptText(entry);
    if (text != null) {
      prompts.add((
        uuid: at,
        parentUuid: parent is String ? parent : null,
        text: text,
      ));
    }
    if (entry['isCompactSummary'] == true) break;
    at = parent is String ? parent : null;
  }
  return prompts.reversed.toList();
}

String? _promptText(Map<Object?, Object?> entry) {
  if (entry['type'] != 'user' || entry['isMeta'] == true) return null;
  if (entry['isCompactSummary'] == true) return null;
  final message = entry['message'];
  if (message is! Map) return null;
  final content = message['content'];
  if (content is String) return content;
  if (content is! List) return null;
  final texts = <String>[];
  for (final block in content) {
    if (block is! Map) continue;
    if (block['type'] == 'tool_result') return null;
    if (block['type'] == 'text' && block['text'] is String) {
      texts.add(block['text'] as String);
    }
  }
  return texts.isEmpty ? null : texts.join('\n');
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
