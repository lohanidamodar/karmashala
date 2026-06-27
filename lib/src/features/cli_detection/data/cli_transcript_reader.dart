import 'dart:convert';
import 'dart:io';

import '../../agents/domain/agent_kind.dart';

/// A single message parsed from a CLI session transcript file, normalized to the
/// roles our chat view renders.
class TranscriptMessage {
  const TranscriptMessage({required this.role, required this.text});

  /// `user`, `agent`, or `tool`.
  final String role;
  final String text;
}

/// Reads a CLI session's full transcript (Claude Code / Codex JSONL) into a flat
/// list of [TranscriptMessage]s, oldest first. Best-effort: malformed lines are
/// skipped and an unreadable file yields an empty list.
Future<List<TranscriptMessage>> readCliTranscript(
  String filePath,
  AgentKind cli,
) async {
  final file = File(filePath);
  if (!await file.exists()) return const [];

  final messages = <TranscriptMessage>[];
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
      switch (cli) {
        case AgentKind.claudeCode:
        case AgentKind.antigravity:
          _parseClaudeLine(decoded, messages);
        case AgentKind.codex:
          _parseCodexLine(decoded, messages);
      }
    }
  } catch (_) {
    // Truncated/locked file — return whatever parsed.
  }
  return messages;
}

void _parseClaudeLine(Map<String, dynamic> json, List<TranscriptMessage> out) {
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
          if (name is String) _add(out, 'tool', 'tool: $name');
      }
    }
  }
}

void _parseCodexLine(Map<String, dynamic> json, List<TranscriptMessage> out) {
  final payload = json['payload'];
  if (payload is! Map) return;
  if (payload['type'] != 'message') return;
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

void _add(List<TranscriptMessage> out, String role, Object? text) {
  if (text is! String) return;
  final trimmed = text.trim();
  if (trimmed.isEmpty) return;
  out.add(TranscriptMessage(role: role, text: trimmed));
}
