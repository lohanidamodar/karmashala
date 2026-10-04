import 'dart:convert';

import 'package:agent_cli/descriptors.dart' show AgentPlan, AgentPlanItem;
import 'package:agent_cli/descriptors.dart' show AgentPlanItemState;
import 'package:agent_cli/read.dart' show CompactionBoundary, TranscriptMessage;
import 'package:agent_cli/stream.dart' show ToolActivity, boundedToolOutput;
import 'package:karmashala_session_engine/store.dart'
    show SessionMessage, SessionMessageDao;

import '../acp/acp_extensions.dart';

/// One row of `session_messages` as a transcript row: its [ordinal] is its
/// index, [revision] is when it last changed.
typedef ProjectedMessage = ({
  int ordinal,
  int revision,
  TranscriptMessage message,
});

/// A whole session as transcript rows, with the revision each last changed at.
typedef ProjectedTranscript = ({
  int revision,
  List<TranscriptMessage> messages,
  List<int> changedAt,
});

/// **A session's transcript read from `session_messages`** rather than from
/// the agent's own file (ACP design, C3): the server wrote the rows, so a
/// row's revision is the record's own and a client is sent only what moved.
class SessionMessageTranscriptSource {
  SessionMessageTranscriptSource(this.messages);

  final SessionMessageDao messages;

  /// Every session served from the table has this generation: the table is
  /// one record, read in place, and its revisions outlive this process.
  static const String generation = 'messages';

  int latestRevision(String sessionId) => messages.latestRevision(sessionId);

  /// The whole session, oldest first.
  ProjectedTranscript readAll(String sessionId) {
    final rows = messages.listAfter(sessionId);
    var revision = 0;
    for (final row in rows) {
      if (row.revision > revision) revision = row.revision;
    }
    return (
      revision: revision,
      messages: [for (final row in rows) project(row)],
      changedAt: [for (final row in rows) row.revision],
    );
  }

  /// The rows that changed after [revision], by ordinal.
  List<ProjectedMessage> readSince(String sessionId, int revision) => [
    for (final row in messages.listSince(sessionId, revision))
      (ordinal: row.ordinal, revision: row.revision, message: project(row)),
  ];

  /// [row] as the chat view draws it. A tool call still open is marked
  /// `pendingToolUseId` and has no output, which is how the view tells
  /// "running" from "answered with nothing"; a plan rides on the row's tool.
  static TranscriptMessage project(SessionMessage row) {
    final tool = _toolOf(row);
    return TranscriptMessage(
      role: row.role.name,
      text: row.text,
      thinking: row.thinking,
      tool: tool?.activity,
      at: row.createdAt,
      pendingToolUseId: tool?.pendingId,
      compaction: _compactionOf(row.messageId),
    );
  }

  /// The boundary a compaction row marks, as a terminal transcript's
  /// summary row carries it.
  static CompactionBoundary? _compactionOf(String? messageId) {
    const marker = AcpExtensions.compactionMessageId;
    if (messageId == null || !messageId.startsWith(marker)) return null;
    final trigger = messageId.length > marker.length + 1
        ? messageId.substring(marker.length + 1)
        : null;
    return CompactionBoundary(trigger: trigger);
  }

  static ({ToolActivity activity, String? pendingId})? _toolOf(
    SessionMessage row,
  ) {
    final plan = _planOf(row.planJson);
    final json = _object(row.toolJson);
    if (json == null) {
      if (plan == null) return null;
      return (
        activity: ToolActivity(
          name: 'plan',
          subject: plan.headline,
          plan: plan,
        ),
        pendingId: null,
      );
    }
    final status = _string(json['status'])?.toLowerCase();
    final open = status == null || _openStatuses.contains(status);
    final failed = status == 'failed' || status == 'error';
    String? output;
    var truncated = false;
    if (!open) {
      final text = _outputOf(json);
      if (text != null) (output, truncated) = boundedToolOutput(text);
    }
    return (
      activity: ToolActivity(
        name:
            _string(json['title']) ??
            _string(json['name']) ??
            _string(json['kind']) ??
            'tool',
        subject: _subjectOf(json['locations']),
        output: output,
        outputTruncated: truncated,
        isError: failed,
        plan: plan,
      ),
      pendingId: open ? (_string(json['toolCallId']) ?? row.id) : null,
    );
  }

  static const Set<String> _openStatuses = {
    'pending',
    'in_progress',
    'running',
  };

  /// The first location's path, as the identifying line of the call.
  static String? _subjectOf(Object? locations) {
    if (locations is! List) return null;
    for (final location in locations) {
      if (location is! Map) continue;
      final path = _string(location['path']);
      if (path == null) continue;
      final line = location['line'];
      return line is int ? '$path:$line' : path;
    }
    return null;
  }

  /// What the call answered: its content blocks' text, else its raw output.
  static String? _outputOf(Map<String, Object?> json) {
    final content = json['content'];
    final parts = <String>[];
    if (content is List) {
      for (final block in content) {
        if (block is! Map) continue;
        switch (block['type']) {
          case 'content':
            final inner = block['content'];
            final text = inner is Map ? _string(inner['text']) : null;
            if (text != null) parts.add(text);
          case 'diff':
            final path = _string(block['path']);
            if (path != null) parts.add('edited $path');
          case 'terminal':
            final id = _string(block['terminalId']);
            if (id != null) parts.add('terminal $id');
        }
      }
    }
    if (parts.isNotEmpty) return parts.join('\n');
    final raw = json['rawOutput'];
    if (raw == null) return null;
    return raw is String ? raw : jsonEncode(raw);
  }

  /// Either the plan's wire form (`items`) or ACP's `plan` update
  /// (`entries` of `content`/`status`). Null when it is neither.
  static AgentPlan? _planOf(String? planJson) {
    final json = _object(planJson);
    if (json == null) return null;
    try {
      if (json['items'] is List) return AgentPlan.fromJson(json);
    } on FormatException {
      return null;
    }
    final entries = json['entries'];
    if (entries is! List) return null;
    return AgentPlan(
      items: [
        for (final entry in entries)
          if (entry is Map)
            if (_string(entry['content']) case final text?)
              AgentPlanItem(
                text: text,
                state: switch (_string(entry['status'])) {
                  'pending' => AgentPlanItemState.pending,
                  'in_progress' => AgentPlanItemState.inProgress,
                  'completed' => AgentPlanItemState.completed,
                  _ => AgentPlanItemState.unrecorded,
                },
              ),
      ],
    );
  }

  static Map<String, Object?>? _object(String? json) {
    if (json == null || json.isEmpty) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(json);
    } on FormatException {
      return null;
    }
    return decoded is Map ? decoded.cast<String, Object?>() : null;
  }

  static String? _string(Object? value) =>
      value is String && value.isNotEmpty ? value : null;
}
