import 'dart:convert';
import 'dart:io';

import '../../agents/domain/agent_ids.dart';
import '../../sessions/domain/tool_activity.dart';

/// A single message parsed from a CLI session transcript file, normalized to the
/// roles our chat view renders.
class TranscriptMessage {
  const TranscriptMessage({
    required this.role,
    required this.text,
    this.tool,
  });

  /// `user`, `agent`, or `tool`.
  final String role;
  final String text;

  /// The structured call behind a `tool` message: what it ran, and what it
  /// answered. Null for the other two roles.
  final ToolActivity? tool;
}

/// Reads a CLI session's full transcript (Claude Code / Codex JSONL) into a flat
/// list of [TranscriptMessage]s, oldest first. Best-effort: malformed lines are
/// skipped and an unreadable file yields an empty list.
Future<List<TranscriptMessage>> readCliTranscript(
  String filePath,
  String cli,
) async {
  // Antigravity's own file is a SQLite database whose message columns are
  // protobuf in an unpublished schema, so there is nothing here to parse — see
  // the design note Refused by name rather than
  // left to fail: without this the loop below reads a binary file as UTF-8
  // lines every two seconds behind the imported-session detail pane, and
  // arrives at the same empty list by throwing.
  if (cli == AgentIds.antigravity) return const [];

  final file = File(filePath);
  if (!await file.exists()) return const [];

  final messages = <TranscriptMessage>[];
  // Correlates a result back to the call it answers: Claude Code echoes the
  // `tool_use.id` as `tool_use_id`, Codex echoes `call_id`. Kept for the whole
  // file because the pair is two lines apart at best and a whole turn apart at
  // worst — and an id we never see again simply stays here, costing a string.
  final pending = <String, int>{};
  try {
    await for (final line
        in file
            .openRead()
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
      if (line.isEmpty) continue;
      final Object? decoded;
      try {
        decoded = jsonDecode(line);
      } on FormatException {
        continue;
      }
      if (decoded is! Map<String, dynamic>) continue;
      // Claude's shape is the default: it is the least-wrong guess for an
      // agent we have no reader for.
      if (cli == AgentIds.codex) {
        _parseCodexLine(decoded, messages, pending);
      } else {
        _parseClaudeLine(decoded, messages, pending);
      }
    }
  } catch (_) {
    // Truncated/locked file — return whatever parsed.
  }
  return messages;
}

void _parseClaudeLine(
  Map<String, dynamic> json,
  List<TranscriptMessage> out,
  Map<String, int> pending,
) {
  final type = json['type'];
  if (type != 'user' && type != 'assistant') return;
  final message = json['message'];
  if (message is! Map) return;
  final content = message['content'];
  final role = type == 'user' ? 'user' : 'agent';

  if (content is String) {
    _add(out, role, content);
    return;
  }
  if (content is! List) return;
  for (final part in content) {
    if (part is String) {
      _add(out, role, part);
    } else if (part is Map) {
      switch (part['type']) {
        case 'text':
          _add(out, role, part['text']);
        case 'tool_use':
          final name = part['name'];
          if (name is String) {
            final activity = toolActivityFor(name, part['input']);
            final id = part['id'];
            if (id is String) pending[id] = out.length;
            out.add(
              TranscriptMessage(
                role: 'tool',
                text: activity.summary,
                tool: activity,
              ),
            );
          }
        case 'tool_result':
          _attachResult(
            out,
            pending,
            id: part['tool_use_id'],
            output: _claudeResultText(part['content']),
            isError: part['is_error'] == true,
          );
      }
    }
  }
}

/// The text of a Claude `tool_result`'s content.
///
/// `image` blocks are read for their existence and then dropped: their `data`
/// is a base64 copy of the file, one real transcript carried 96 of them, and
/// the picture is drawn from the path on disk instead
/// (`TranscriptImagePreview`).
String _claudeResultText(Object? content) {
  if (content is String) return content;
  if (content is! List) return '';
  final parts = <String>[];
  for (final block in content) {
    if (block is Map && block['type'] == 'text' && block['text'] is String) {
      parts.add(block['text'] as String);
    }
  }
  return parts.join('\n');
}

void _parseCodexLine(
  Map<String, dynamic> json,
  List<TranscriptMessage> out,
  Map<String, int> pending,
) {
  final payload = json['payload'];
  if (payload is! Map) return;
  switch (payload['type']) {
    case 'message':
      _parseCodexMessage(payload, out);
    // Codex names its shell differently depending on the tool surface —
    // `function_call` for the classic `shell`, `custom_tool_call` for the
    // `exec` sandbox — but both carry a name, a `call_id` and an answer.
    case 'function_call':
    case 'custom_tool_call':
      final name = payload['name'];
      if (name is! String) return;
      final activity = ToolActivity(
        name: name,
        subject: _codexSubject(payload),
      );
      final callId = payload['call_id'];
      if (callId is String) pending[callId] = out.length;
      out.add(
        TranscriptMessage(
          role: 'tool',
          text: activity.summary,
          tool: activity,
        ),
      );
    case 'function_call_output':
    case 'custom_tool_call_output':
      _attachResult(
        out,
        pending,
        id: payload['call_id'],
        output: _codexResultText(payload['output']),
        isError: false,
      );
  }
}

void _parseCodexMessage(Map<dynamic, dynamic> payload, List<TranscriptMessage> out) {
  final role = payload['role'] == 'user' ? 'user' : 'agent';
  final content = payload['content'];
  if (content is String) {
    _add(out, role, content);
    return;
  }
  if (content is! List) return;
  for (final block in content) {
    if (block is! Map) continue;
    final t = block['type'];
    if (t == 'input_text' || t == 'output_text' || t == 'text') {
      _add(out, role, block['text']);
    }
  }
}

/// The identifying line of a Codex call.
///
/// `shell` sends `arguments` as a JSON string holding `command` as an argv
/// list, which is the clean case; `exec` sends `input` as a snippet of the
/// script it is about to run, of which the first line is the honest summary.
String? _codexSubject(Map<dynamic, dynamic> payload) {
  final input = payload['input'];
  if (input is String && input.trim().isNotEmpty) {
    return input.trim().split('\n').first;
  }
  final arguments = payload['arguments'];
  if (arguments is! String || arguments.trim().isEmpty) return null;
  try {
    final decoded = jsonDecode(arguments);
    if (decoded is Map) {
      final command = decoded['command'];
      if (command is List) return command.join(' ');
      if (command is String) return command;
      final entry = toolSubjectEntryFor(decoded);
      if (entry != null) return entry.value;
    }
  } on FormatException {
    // Arguments we cannot read are still better shown than hidden.
  }
  return arguments.trim().split('\n').first;
}

/// The text of a Codex call's output, which is either a string or the same
/// `input_text` blocks its messages use.
String _codexResultText(Object? output) {
  if (output is String) return output;
  if (output is! List) return '';
  final parts = <String>[];
  for (final block in output) {
    if (block is Map && block['text'] is String) {
      parts.add(block['text'] as String);
    }
  }
  return parts.join();
}

/// Hangs a result on the call it answers, or drops it when that call is not in
/// this file — a transcript read while it is being written ends mid-pair.
void _attachResult(
  List<TranscriptMessage> out,
  Map<String, int> pending, {
  required Object? id,
  required String output,
  required bool isError,
}) {
  if (id is! String) return;
  final index = pending.remove(id);
  if (index == null || index >= out.length) return;
  final call = out[index].tool;
  if (call == null) return;
  final trimmed = output.trimRight();
  final (bounded, truncated) = boundedToolOutput(trimmed);
  out[index] = TranscriptMessage(
    role: out[index].role,
    text: out[index].text,
    tool: call.withResult(
      output: bounded.isEmpty ? null : bounded,
      outputTruncated: truncated,
      isError: isError,
    ),
  );
}

void _add(List<TranscriptMessage> out, String role, Object? text) {
  if (text is! String) return;
  final trimmed = text.trim();
  if (trimmed.isEmpty) return;
  out.add(TranscriptMessage(role: role, text: trimmed));
}
