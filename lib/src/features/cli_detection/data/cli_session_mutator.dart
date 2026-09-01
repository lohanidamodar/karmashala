import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../agents/domain/agent_ids.dart';
import '../domain/detected_session.dart';

/// Renames and deletes detected CLI sessions on disk, matching what each CLI
/// itself does (ported from the reference Karmashala CLI):
///
/// * **Claude** rename appends a `{"type":"custom-title",…}` line (what
///   `/rename` writes); delete removes the `.jsonl` and any `~/.claude/sessions`
///   resume-index entry.
/// * **Codex** rename/delete edit the `thread_name` / entry in
///   `<codexHome>/session_index.jsonl`; delete also removes the rollout file.
class CliSessionMutator {
  const CliSessionMutator();

  Future<void> rename(DetectedSession session, String newTitle) {
    final title = newTitle.trim();
    if (title.isEmpty) {
      throw ArgumentError('Title cannot be empty');
    }
    return session.cli == AgentIds.codex
        ? _renameCodex(session, title)
        : _renameClaude(session, title);
  }

  Future<void> delete(DetectedSession session) {
    return session.cli == AgentIds.codex
        ? _deleteCodex(session)
        : _deleteClaude(session);
  }

  // --- Claude ---------------------------------------------------------------

  Future<void> _renameClaude(DetectedSession session, String title) async {
    final file = File(session.filePath);
    if (!await file.exists()) {
      throw FileSystemException('Session file missing', session.filePath);
    }
    final entry = {
      'type': 'custom-title',
      'sessionId': session.sessionId,
      'customTitle': title,
    };
    final endsWithNewline = await _endsWithNewline(file);
    final sink = file.openWrite(mode: FileMode.append);
    try {
      if (!endsWithNewline) sink.writeln();
      sink.writeln(jsonEncode(entry));
      await sink.flush();
    } finally {
      await sink.close();
    }
  }

  Future<void> _deleteClaude(DetectedSession session) async {
    final file = File(session.filePath);
    if (await file.exists()) await file.delete();
    await _removeClaudeIndexEntries(
      session.storeHome,
      (entry) => entry['sessionId'] == session.sessionId,
    );
  }

  Future<void> _removeClaudeIndexEntries(
    String claudeHome,
    bool Function(Map<String, dynamic>) match,
  ) async {
    final indexDir = Directory(p.join(claudeHome, 'sessions'));
    if (!await indexDir.exists()) return;
    await for (final entity in indexDir.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      try {
        final decoded = jsonDecode(await entity.readAsString());
        if (decoded is Map<String, dynamic> && match(decoded)) {
          await entity.delete();
        }
      } catch (_) {}
    }
  }

  Future<bool> _endsWithNewline(File f) async {
    final len = await f.length();
    if (len == 0) return true;
    final raf = await f.open();
    try {
      await raf.setPosition(len - 1);
      return await raf.readByte() == 0x0a;
    } finally {
      await raf.close();
    }
  }

  // --- Codex ----------------------------------------------------------------

  File _codexIndex(DetectedSession session) =>
      File(p.join(session.storeHome, 'session_index.jsonl'));

  Future<void> _renameCodex(DetectedSession session, String title) async {
    final index = _codexIndex(session);
    final lines = await _readIndexLines(index);
    var found = false;
    final out = <String>[];
    for (final line in lines) {
      final entry = _tryDecode(line);
      if (entry != null && entry['id'] == session.sessionId) {
        found = true;
        out.add(jsonEncode({...entry, 'thread_name': title}));
      } else {
        out.add(line);
      }
    }
    if (!found) {
      out.add(jsonEncode({'id': session.sessionId, 'thread_name': title}));
    }
    await index.writeAsString('${out.join('\n')}\n');
  }

  Future<void> _deleteCodex(DetectedSession session) async {
    final file = File(session.filePath);
    if (await file.exists()) await file.delete();
    final index = _codexIndex(session);
    if (!await index.exists()) return;
    final lines = await _readIndexLines(index);
    final out = [
      for (final line in lines)
        if (_tryDecode(line)?['id'] != session.sessionId) line,
    ];
    await index.writeAsString(out.isEmpty ? '' : '${out.join('\n')}\n');
  }

  Future<List<String>> _readIndexLines(File index) async {
    if (!await index.exists()) return const [];
    return (await index.readAsString())
        .split('\n')
        .where((l) => l.trim().isNotEmpty)
        .toList();
  }

  Map<String, dynamic>? _tryDecode(String line) {
    try {
      final decoded = jsonDecode(line);
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    }
  }
}
