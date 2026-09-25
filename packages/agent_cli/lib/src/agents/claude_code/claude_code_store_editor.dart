import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../cli_detection/domain/detected_session.dart';
import '../adapter/agent_store_editor.dart';

/// Renames and removes Claude Code conversations the way the CLI does: a
/// `custom-title` record appended to the transcript, and the resume index in
/// `<home>/sessions/*.json` kept in step with a delete.
class ClaudeCodeStoreEditor implements AgentStoreEditor {
  const ClaudeCodeStoreEditor();

  @override
  Future<void> rename(
    DetectedSession session,
    String title,
    StoreEditContext context,
  ) async {
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

  /// Drops the resume-index entries naming any of [conversationIds], in one
  /// listing.
  @override
  Future<void> prune(
    String storeHome,
    Set<String> conversationIds,
    StoreEditContext context,
  ) async {
    final counters = context.counters;
    final indexDir = Directory(p.join(storeHome, 'sessions'));
    if (!await indexDir.exists()) return;
    counters.storeScans++;
    await for (final entity in indexDir.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      counters.indexEntriesRead++;
      final Object? decoded;
      try {
        decoded = jsonDecode(await entity.readAsString());
      } on Object {
        continue; // Not an entry this app can judge; a delete that fails is reported.
      }
      if (decoded is Map<String, dynamic> &&
          conversationIds.contains(decoded['sessionId'])) {
        await entity.delete();
        counters.indexWrites++;
      }
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
}
