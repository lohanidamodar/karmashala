import 'dart:convert';
import 'dart:io';

import '../adapter/agent_import_audit.dart';
import 'codex_store_reader.dart';

/// Codex's `codex exec` runs (and MCP or subagent ones), which an older import
/// took as conversations: titled by an injected `<recommended_plugins>` block
/// and never resumable. A rollout says which it is in its opening
/// `session_meta.source`.
class CodexImportAudit implements AgentImportAudit {
  const CodexImportAudit();

  @override
  String get recordNoun => 'Codex run';

  @override
  Future<bool> isNotConversation(String path) async {
    final source = await _sourceOf(path);
    return source != _unread && !isInteractiveCodexSource(source);
  }

  /// A rollout's `session_meta.source`, or [_unread] when the file is not
  /// here to read or opens with no `session_meta`.
  static Future<Object?> _sourceOf(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return _unread;
      final first = await file
          .openRead()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first;
      final json = jsonDecode(first);
      if (json is! Map || json['type'] != 'session_meta') return _unread;
      final payload = json['payload'];
      return payload is Map ? payload['source'] : _unread;
    } on Object {
      return _unread;
    }
  }

  static const Object _unread = Object();
}
