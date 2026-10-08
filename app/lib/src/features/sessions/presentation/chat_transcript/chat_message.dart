// The transcript's message value and the roles the view writes itself.

part of '../chat_transcript.dart';

/// The row the transcript view writes itself, saying a compaction happened
/// here. Its own role, because an unknown role is read as the agent's.
const String kCompactionNoticeRole = 'compaction';

/// The row a switched session's transcript holds where another agent took
/// over: drawn as a divider whose text is what that agent was handed.
const String kAgentSwitchNoticeRole = 'agentSwitch';

/// A normalized chat message for the transcript view, independent of whether it
/// came from a native session's event log or an imported CLI transcript.
class ChatMessage {
  const ChatMessage({
    required this.role,
    required this.text,
    this.tool,
    this.thinking,
    this.at,
    this.pending = false,
    this.pendingToolUseId,
    this.agentName,
    this.agentId,
    this.detail,
    this.queued = false,
    this.images = const [],
    this.model,
  });

  /// `user`, `agent`, `tool`, or `error`.
  final String role;
  final String text;

  /// The structured call behind a `tool` row, when the source carried one. Null
  /// for a tool line we only have prose for; those render exactly as before.
  final ToolActivity? tool;

  final String? thinking;

  /// When the message was written.
  final DateTime? at;

  /// A tool call the source says is unanswered. Not `tool.output == null`: a
  /// call answered with nothing has no output either.
  final bool pending;

  /// The unanswered call's id, when the source named it: what an ask about
  /// this call is matched by.
  final String? pendingToolUseId;

  /// The agent that spoke, named on the first agent row of a turn and on a
  /// switch divider in a session that switched agent; null everywhere else.
  final String? agentName;
  final String? agentId;

  /// Text folded under a notice until it is opened: what a compaction kept.
  final String? detail;

  /// A `user` row the person sent while the agent was still working.
  final bool queued;

  /// Images the person pasted into a `user` row, as paths on the session's
  /// machine.
  final List<String> images;

  /// The label of the model that wrote this agent turn, set only where it
  /// differs from the turn before (and on the first); null everywhere else.
  final String? model;

  /// By value: a live transcript is re-parsed whole on every poll, and an equal
  /// message is what lets its row skip the rebuild.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ChatMessage &&
          other.role == role &&
          other.at == at &&
          other.pending == pending &&
          other.pendingToolUseId == pendingToolUseId &&
          other.agentName == agentName &&
          other.agentId == agentId &&
          other.thinking == thinking &&
          other.detail == detail &&
          other.queued == queued &&
          other.model == model &&
          _samePaths(other.images, images) &&
          _sameTool(other.tool, tool) &&
          other.text == text;

  @override
  int get hashCode => Object.hash(role, text, thinking, at, tool?.name);
}

bool _samePaths(List<String> a, List<String> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// [ToolActivity] has no equality of its own; these are every field it draws.
bool _sameTool(ToolActivity? a, ToolActivity? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return false;
  return a.name == b.name &&
      a.subject == b.subject &&
      a.imagePath == b.imagePath &&
      a.output == b.output &&
      a.outputTruncated == b.outputTruncated &&
      a.isError == b.isError &&
      a.plan == b.plan &&
      a.kind == b.kind &&
      a.editsTruncated == b.editsTruncated &&
      a.endedAt == b.endedAt &&
      _sameEdits(a.edits, b.edits);
}

bool _sameEdits(List<FileEditRecord> a, List<FileEditRecord> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
