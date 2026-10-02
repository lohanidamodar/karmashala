import 'dart:async';
import 'dart:convert';

import 'package:karmashala_acp/karmashala_acp.dart';
import 'package:karmashala_session_engine/store.dart'
    show SessionMessage, SessionMessageDao, SessionMessageRole;

/// **An ACP session's `session/update`s as `session_messages` rows** (design
/// C3/C4): the prompt as a `user` row, chunks coalesced into one `agent` row
/// until a new `messageId`, a tool call or the turn's end closes it, each tool
/// call as a `tool` row patched by its id, the plan as a row of its own. Every
/// write is followed by [onChanged], so watchers read it at once.
class AcpConversationWriter {
  AcpConversationWriter({
    required this.sessionId,
    required this.messages,
    required this.newId,
    required this.onChanged,
    DateTime Function()? now,
    this.coalesce = const Duration(milliseconds: 100),
    this.tailLines = 400,
  }) : _now = now ?? (() => DateTime.now().toUtc());

  final String sessionId;
  final SessionMessageDao messages;
  final String Function() newId;
  final void Function() onChanged;
  final DateTime Function() _now;

  /// How long chunks are gathered before the open agent row is written.
  final Duration coalesce;

  /// How many rendered lines are kept for a screen-like tail.
  final int tailLines;

  final _text = StringBuffer();
  final _thinking = StringBuffer();
  String? _openRow;
  String? _openMessageId;
  String? _planRow;
  Timer? _timer;
  final _tools = <String, _ToolRow>{};
  final _rendered = <String>[];
  var _closed = false;

  /// The latest state of each tool call this turn, by id.
  ToolCallUpdate? toolCall(String toolCallId) => _tools[toolCallId]?.state;

  /// The person's message, written as the turn starts.
  void user(String text) {
    _closeAgentRow();
    _append(SessionMessageRole.user, text: text);
    _render('You: $text');
  }

  /// One update from the agent. Kinds this writer does not store are ignored.
  void update(SessionUpdate update) {
    if (_closed) return;
    switch (update) {
      case AgentMessageChunk(:final content, :final messageId):
        _chunk(messageId, _text, content);
      case AgentThoughtChunk(:final content, :final messageId):
        _chunk(messageId, _thinking, content);
      case ToolCallUpdate():
        _tool(update);
      case PlanUpdate(:final entries):
        _plan(entries);
      case UserMessageChunk() ||
          AvailableCommandsUpdate() ||
          CurrentModeUpdate() ||
          ConfigOptionUpdate() ||
          SessionInfoUpdate() ||
          UsageUpdate() ||
          UnknownUpdate():
        break;
    }
  }

  /// Writes what is buffered now, without closing the agent row.
  void flush() {
    _timer?.cancel();
    _timer = null;
    if (_text.isEmpty && _thinking.isEmpty) return;
    final text = _text.toString();
    final thinking = _thinking.toString();
    _text.clear();
    _thinking.clear();
    final open = _openRow;
    if (open == null) {
      _openRow = _append(
        SessionMessageRole.agent,
        text: text,
        thinking: thinking.isEmpty ? null : thinking,
        messageId: _openMessageId,
      );
    } else {
      messages.patch(
        open,
        appendText: text.isEmpty ? null : text,
        appendThinking: thinking.isEmpty ? null : thinking,
      );
      onChanged();
    }
    if (text.isNotEmpty) _render('Agent: $text');
  }

  /// The turn ended: everything buffered is written and the rows close.
  void turnEnded() {
    flush();
    _openRow = null;
    _openMessageId = null;
    _planRow = null;
    _tools.clear();
  }

  /// The last [lines] rendered lines, as a screen's tail reads.
  List<String> tail(int lines) => _rendered.length <= lines
      ? List.unmodifiable(_rendered)
      : List.unmodifiable(_rendered.sublist(_rendered.length - lines));

  void close() {
    _closed = true;
    _timer?.cancel();
    _timer = null;
  }

  void _chunk(String? messageId, StringBuffer into, ContentBlock content) {
    if (messageId != null &&
        _openMessageId != null &&
        messageId != _openMessageId) {
      _closeAgentRow();
    }
    _openMessageId ??= messageId;
    into.write(_textOf(content));
    _timer ??= Timer(coalesce, flush);
  }

  void _tool(ToolCallUpdate update) {
    final known = _tools[update.toolCallId];
    if (known == null) {
      _closeAgentRow();
      final row = _append(
        SessionMessageRole.tool,
        toolJson: jsonEncode(update.toToolCallJson()),
      );
      _tools[update.toolCallId] = _ToolRow(row, update);
      _render(
        '[tool] ${_titleOf(update)} (${update.status?.raw ?? 'pending'})',
      );
      return;
    }
    final merged = known.state.merge(update);
    known.state = merged;
    messages.patch(known.rowId, toolJson: jsonEncode(merged.toToolCallJson()));
    onChanged();
    if (update.status != null) {
      _render('[tool] ${_titleOf(merged)} (${update.status!.raw})');
    }
  }

  void _plan(List<PlanEntry> entries) {
    _closeAgentRow();
    final json = jsonEncode({
      'entries': [for (final entry in entries) entry.toJson()],
    });
    final row = _planRow;
    if (row == null) {
      _planRow = _append(SessionMessageRole.agent, planJson: json);
    } else {
      messages.patch(row, planJson: json);
      onChanged();
    }
    _render('[plan] ${entries.length} step(s)');
  }

  void _closeAgentRow() {
    flush();
    _openRow = null;
    _openMessageId = null;
  }

  String _append(
    SessionMessageRole role, {
    String text = '',
    String? thinking,
    String? toolJson,
    String? planJson,
    String? messageId,
  }) {
    final at = _now();
    final row = messages.append(
      SessionMessage(
        id: newId(),
        sessionId: sessionId,
        role: role,
        text: text,
        thinking: thinking,
        toolJson: toolJson,
        planJson: planJson,
        messageId: messageId,
        createdAt: at,
        updatedAt: at,
      ),
    );
    onChanged();
    return row.id;
  }

  void _render(String text) {
    for (final line in const LineSplitter().convert(text)) {
      _rendered.add(line);
    }
    if (_rendered.length > tailLines) {
      _rendered.removeRange(0, _rendered.length - tailLines);
    }
  }

  static String _titleOf(ToolCallUpdate call) =>
      call.title ?? call.name ?? call.toolCallId;

  /// A block as text: its words, or a marker for what has none.
  static String _textOf(ContentBlock content) => switch (content) {
    TextContent(:final text) => text,
    ImageContent() => '[image]',
    AudioContent() => '[audio]',
    ResourceLinkContent(:final uri) => uri,
    EmbeddedResourceContent(:final resource) =>
      resource.text ?? '[${resource.uri}]',
    UnknownContent(:final type) => '[$type]',
  };
}

final class _ToolRow {
  _ToolRow(this.rowId, this.state);

  final String rowId;
  ToolCallUpdate state;
}
