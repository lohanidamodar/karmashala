import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../agents/domain/agent_kind.dart';
import '../../environments/domain/environment_path.dart';
import '../domain/detected_session.dart';

/// Reads Claude Code sessions from a `.claude` store directory.
///
/// Ported from the reference Chitragupta CLI and adapted to bind sessions to an
/// execution environment. Each `<claudeHome>/projects/<dir>/<id>.jsonl` is one
/// session; the real `cwd` is taken from inside the file (the folder name is a
/// lossy dash-encoding). Title precedence: `custom-title` > `ai-title` > first
/// user message preview. The `entrypoint` field distinguishes SDK-spawned
/// subagents.
class ClaudeStoreReader {
  const ClaudeStoreReader();

  /// Reads all sessions under [claudeHome] (a `.claude` directory), tagging them
  /// with [environmentId]. Returns an empty list if the store is absent.
  Future<List<DetectedSession>> read(
    String claudeHome,
    String environmentId,
  ) async {
    final projectsDir = Directory(p.join(claudeHome, 'projects'));
    if (!await projectsDir.exists()) return const [];

    final sessions = <DetectedSession>[];
    await for (final projectEntity in projectsDir.list()) {
      if (projectEntity is! Directory) continue;
      await for (final fileEntity in projectEntity.list()) {
        if (fileEntity is! File || !fileEntity.path.endsWith('.jsonl')) {
          continue;
        }
        final session = await _readSession(
          fileEntity,
          claudeHome,
          environmentId,
        );
        if (session != null) sessions.add(session);
      }
    }
    return sessions;
  }

  Future<DetectedSession?> _readSession(
    File file,
    String claudeHome,
    String environmentId,
  ) async {
    String? aiTitle;
    String? customTitle;
    String preview = '';
    String? cwd;
    String? entrypoint;

    try {
      await for (final line
          in file
              .openRead()
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
        if (line.isEmpty) continue;
        final Map<String, dynamic> json;
        try {
          final decoded = jsonDecode(line);
          if (decoded is! Map<String, dynamic>) continue;
          json = decoded;
        } on FormatException {
          continue;
        }
        switch (json['type']) {
          case 'ai-title':
            final t = json['aiTitle'];
            if (t is String && t.trim().isNotEmpty) aiTitle = t;
          case 'custom-title':
            final t = json['customTitle'];
            if (t is String && t.trim().isNotEmpty) customTitle = t;
          case 'user':
            if (preview.isEmpty) preview = _extractUserMessage(json);
            cwd ??= json['cwd'] as String?;
            if (entrypoint == null) {
              final ep = json['entrypoint'];
              if (ep is String && ep.isNotEmpty) entrypoint = ep;
            }
        }
        cwd ??= json['cwd'] as String?;
      }
    } catch (_) {
      // Corrupt file — keep whatever was collected.
    }

    if (cwd == null || cwd.isEmpty) return null;

    DateTime? modified;
    try {
      modified = (await file.stat()).modified;
    } catch (_) {}

    return DetectedSession(
      cli: AgentKind.claudeCode,
      sessionId: p.basenameWithoutExtension(file.path),
      cwd: EnvironmentPath(environmentId: environmentId, path: cwd),
      filePath: file.path,
      storeHome: claudeHome,
      title: customTitle ?? aiTitle,
      preview: preview,
      modifiedAt: modified,
      entrypoint: entrypoint,
    );
  }

  static String _extractUserMessage(Map<String, dynamic> entry) {
    final msg = entry['message'];
    if (msg is String) return _truncate(msg);
    if (msg is Map<String, dynamic>) {
      final content = msg['content'];
      if (content is String) return _truncate(content);
      if (content is List) {
        for (final part in content) {
          if (part is Map<String, dynamic>) {
            final text = part['text'];
            if (text is String && text.trim().isNotEmpty) {
              return _truncate(text);
            }
          } else if (part is String && part.trim().isNotEmpty) {
            return _truncate(part);
          }
        }
      }
    }
    return '';
  }

  static String _truncate(String s, [int max = 120]) {
    final trimmed = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (trimmed.length <= max) return trimmed;
    return '${trimmed.substring(0, max - 1)}…';
  }
}
