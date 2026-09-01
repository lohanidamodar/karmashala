import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../agents/domain/agent_ids.dart';
import '../../environments/domain/environment_path.dart';
import '../domain/detected_session.dart';

/// Reads Codex sessions from a `.codex` store directory.
///
/// Ported from the reference Karmashala CLI. Codex has no project list: each
/// `<codexHome>/sessions/[YYYY/MM/DD/]rollout-*.jsonl` records its `cwd` in a
/// leading `session_meta` line, and the session's editable label is the
/// `thread_name` in `<codexHome>/session_index.jsonl`.
class CodexStoreReader {
  const CodexStoreReader();

  Future<List<DetectedSession>> read(
    String codexHome,
    String environmentId,
  ) async {
    final sessionsDir = Directory(p.join(codexHome, 'sessions'));
    if (!await sessionsDir.exists()) return const [];

    final threadNames = await _readThreadNames(codexHome);
    final sessions = <DetectedSession>[];

    await for (final entity in sessionsDir.list(recursive: true)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (!name.startsWith('rollout-') || !name.endsWith('.jsonl')) continue;

      final meta = await _readRollout(entity);
      if (meta == null) continue;

      DateTime? modified;
      try {
        modified = (await entity.stat()).modified;
      } catch (_) {}

      sessions.add(
        DetectedSession(
          cli: AgentIds.codex,
          sessionId: meta.id,
          cwd: EnvironmentPath(environmentId: environmentId, path: meta.cwd),
          filePath: entity.path,
          storeHome: codexHome,
          title: threadNames[meta.id],
          preview: meta.preview,
          startedAt: meta.startedAt,
          modifiedAt: modified,
        ),
      );
    }
    return sessions;
  }

  Future<_CodexMeta?> _readRollout(File file) async {
    String? cwd;
    String? id;
    DateTime? startedAt;
    String preview = '';
    var lines = 0;
    try {
      await for (final line
          in file
              .openRead()
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
        if (lines++ > 400 && cwd != null) break;
        if (line.isEmpty) continue;
        final Map<String, dynamic> json;
        try {
          final decoded = jsonDecode(line);
          if (decoded is! Map<String, dynamic>) continue;
          json = decoded;
        } on FormatException {
          continue;
        }
        if (json['type'] == 'session_meta') {
          final payload = json['payload'];
          if (payload is Map) {
            cwd ??= payload['cwd'] as String?;
            id ??= payload['id'] as String?;
            // The payload's own timestamp, not the envelope's. They are not the
            // same moment: in the owner's rollout the conversation began at
            // 10:11:12.953Z and the line recording that was flushed at
            // 10:11:42.945Z — thirty seconds later. Attribution compares this
            // against when a session row was written, so it wants the start.
            startedAt ??=
                _parseTime(payload['timestamp']) ??
                _parseTime(json['timestamp']);
          }
        }
        cwd ??= json['cwd'] as String?;
        id ??= json['id'] as String?;
        if (preview.isEmpty) preview = _extractUserMessage(json);
      }
    } catch (_) {}

    if (cwd == null || cwd.isEmpty) return null;
    id ??= _idFromFileName(p.basename(file.path));
    return _CodexMeta(
      cwd: cwd,
      id: id,
      preview: preview,
      startedAt: startedAt,
    );
  }

  /// An ISO-8601 instant, in UTC, or null for anything else.
  static DateTime? _parseTime(Object? value) {
    if (value is! String || value.isEmpty) return null;
    return DateTime.tryParse(value)?.toUtc();
  }

  /// `rollout-2026-05-25T16-21-53-<uuid>.jsonl` → `<uuid>`.
  static String _idFromFileName(String fileName) {
    final stem = fileName
        .replaceFirst('rollout-', '')
        .replaceFirst('.jsonl', '');
    final uuid = RegExp(r'[0-9a-fA-F-]{36}$').firstMatch(stem);
    return uuid?.group(0) ?? stem;
  }

  static String _extractUserMessage(Map<String, dynamic> json) {
    final payload = json['payload'];
    if (payload is! Map) return '';
    if (payload['type'] != 'message' || payload['role'] != 'user') return '';
    final content = payload['content'];
    if (content is List) {
      for (final block in content) {
        if (block is Map && block['type'] == 'input_text') {
          final text = block['text'];
          if (text is String && text.trim().isNotEmpty) {
            final cleaned = text.replaceAll(RegExp(r'\s+'), ' ').trim();
            return cleaned.length > 120
                ? '${cleaned.substring(0, 119)}…'
                : cleaned;
          }
        }
      }
    }
    return '';
  }

  Future<Map<String, String>> _readThreadNames(String codexHome) async {
    final index = File(p.join(codexHome, 'session_index.jsonl'));
    if (!await index.exists()) return const {};
    final names = <String, String>{};
    try {
      await for (final line
          in index
              .openRead()
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
        if (line.isEmpty) continue;
        try {
          final decoded = jsonDecode(line);
          if (decoded is Map<String, dynamic>) {
            final id = decoded['id'];
            final name = decoded['thread_name'];
            if (id is String && name is String && name.trim().isNotEmpty) {
              names[id] = name;
            }
          }
        } on FormatException {
          continue;
        }
      }
    } catch (_) {}
    return names;
  }
}

class _CodexMeta {
  const _CodexMeta({
    required this.cwd,
    required this.id,
    required this.preview,
    this.startedAt,
  });
  final String cwd;
  final String id;
  final String preview;
  final DateTime? startedAt;
}
