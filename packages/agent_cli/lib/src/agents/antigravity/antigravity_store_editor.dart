import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../cli_detection/domain/detected_session.dart';
import '../adapter/agent_store_editor.dart';

/// Renames and removes Antigravity conversations the way `/rename` and the CLI
/// do: an `annotations/<id>.pbtxt` title, mirrored into
/// `conversation_summaries.db`, and every side file kept in step with a delete.
class AntigravityStoreEditor implements AgentStoreEditor {
  const AntigravityStoreEditor();

  @override
  Future<void> rename(
    DetectedSession session,
    String title,
    StoreEditContext context,
  ) async {
    final annotationsDir = Directory(p.join(session.storeHome, 'annotations'));
    if (!await annotationsDir.exists()) {
      await annotationsDir.create(recursive: true);
    }
    final file = File(
      p.join(annotationsDir.path, '${session.sessionId}.pbtxt'),
    );
    final escaped = _escapeProtobufString(title);
    await file.writeAsString('title:"$escaped"\n');
    context.counters.indexWrites++;

    final summariesPath = p.join(
      session.storeHome,
      'conversation_summaries.db',
    );
    if (await File(summariesPath).exists()) {
      await context.writeSqlite(summariesPath, [
        (
          'UPDATE conversation_summaries SET title = ? WHERE conversation_id = ?',
          [title, session.sessionId],
        ),
      ]);
      context.counters.indexWrites++;
    }
  }

  static String _escapeProtobufString(String s) {
    return s
        .replaceAll(r'\', r'\\')
        .replaceAll('"', r'\"')
        .replaceAll('\n', r'\n')
        .replaceAll('\r', r'\r')
        .replaceAll('\t', r'\t');
  }

  @override
  Future<void> prune(
    String storeHome,
    Set<String> conversationIds,
    StoreEditContext context,
  ) async {
    final counters = context.counters;
    counters.storeScans++;
    for (final id in conversationIds) {
      for (final path in [
        p.join(storeHome, 'annotations', '$id.pbtxt'),
        p.join(storeHome, 'presence', '$id.lock'),
      ]) {
        final file = File(path);
        if (await file.exists()) {
          await file.delete();
          counters.indexWrites++;
        }
      }
    }

    final summariesPath = p.join(storeHome, 'conversation_summaries.db');
    if (await File(summariesPath).exists()) {
      await context.writeSqlite(summariesPath, [
        for (final id in conversationIds)
          (
            'DELETE FROM conversation_summaries WHERE conversation_id = ?',
            [id],
          ),
      ]);
      counters.indexWrites++;
    }

    final lastConvPath = p.join(storeHome, 'cache', 'last_conversations.json');
    final lastConvFile = File(lastConvPath);
    if (await lastConvFile.exists()) {
      final Object? map;
      try {
        map = jsonDecode(await lastConvFile.readAsString());
      } on Object {
        return; // Antigravity's own cache; unreadable is theirs to rebuild.
      }
      if (map is Map<String, dynamic>) {
        var modified = false;
        final updated = Map<String, dynamic>.from(map);
        for (final entry in map.entries) {
          if (conversationIds.contains(entry.value.toString())) {
            updated.remove(entry.key);
            modified = true;
          }
        }
        if (modified) {
          await lastConvFile.writeAsString(jsonEncode(updated));
          counters.indexWrites++;
        }
      }
    }
  }
}
