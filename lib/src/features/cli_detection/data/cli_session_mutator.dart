import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'package:karmashala_core/logging.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart';
import 'codex_app_servers.dart';

/// What a batched delete could not remove. [label] is the session's own title,
/// or the store index, so the report reads as a list rather than a stack trace.
class CliDeleteFailure {
  const CliDeleteFailure({required this.label, required this.error});

  final String label;
  final Object error;

  @override
  String toString() => 'CliDeleteFailure($label, $error)';
}

/// The outcome of [CliSessionMutator.deleteAll]: what went, and what did not.
class CliDeleteReport {
  const CliDeleteReport({required this.deleted, required this.failures});

  static const empty = CliDeleteReport(deleted: 0, failures: []);

  /// Transcripts actually removed. Counted after the fact, never optimistically:
  /// this is the one operation here that nothing can put back.
  final int deleted;

  final List<CliDeleteFailure> failures;

  bool get isComplete => failures.isEmpty;
}

/// Renames and deletes detected CLI sessions the way each CLI does it — see
/// [_renameCodex] for why Codex is asked rather than written to.
class CliSessionMutator {
  CliSessionMutator();

  static final _log = AppLogger.named('cli.sessionMutator');

  /// What a delete actually costs the store, counted rather than timed: index
  /// walks, records decoded, index files rewritten, transcripts removed.
  int storeScans = 0;
  int indexEntriesRead = 0;
  int indexWrites = 0;
  int transcriptsDeleted = 0;

  /// Renames one session in its CLI's own store. Without [codex] a Codex rename
  /// is skipped, never faked by writing a file Codex ignores.
  Future<void> rename(
    DetectedSession session,
    String newTitle, {
    CodexAppServers? codex,
  }) {
    final title = newTitle.trim();
    if (title.isEmpty) {
      throw ArgumentError('Title cannot be empty');
    }
    if (session.cli == AgentIds.antigravity) {
      return _renameAntigravity(session, title);
    }
    return session.cli == AgentIds.codex
        ? _renameCodex(session, title, codex)
        : _renameClaude(session, title);
  }

  /// Deletes one session, throwing if it could not be removed. Implemented as
  /// [deleteAll] of one, so the two cannot treat a store differently.
  Future<void> delete(DetectedSession session) async {
    final report = await deleteAll([session]);
    final failure = report.failures.firstOrNull;
    if (failure != null) throw failure.error;
  }

  /// Deletes every session in [sessions], walking each store's index once
  /// rather than once per session. Never throws: what failed comes back listed.
  Future<CliDeleteReport> deleteAll(Iterable<DetectedSession> sessions) async {
    final groups = <(String, String), List<DetectedSession>>{};
    for (final session in sessions) {
      groups
          .putIfAbsent((session.cli, session.storeHome), () => [])
          .add(session);
    }
    var deleted = 0;
    final failures = <CliDeleteFailure>[];
    for (final entry in groups.entries) {
      final (cli, storeHome) = entry.key;
      final group = entry.value;
      final removed = <String>{};
      for (final session in group) {
        try {
          final file = File(session.filePath);
          if (await file.exists()) {
            await file.delete();
            transcriptsDeleted++;
          }
          removed.add(session.sessionId);
          deleted++;
        } catch (error) {
          failures.add(
            CliDeleteFailure(label: session.displayTitle, error: error),
          );
        }
      }
      if (removed.isEmpty) continue;
      try {
        if (cli == AgentIds.antigravity) {
          await _pruneAntigravityIndex(storeHome, removed);
        } else if (cli == AgentIds.codex) {
          await _pruneCodexIndex(storeHome, removed);
        } else {
          await _pruneClaudeIndex(storeHome, removed);
        }
      } catch (error) {
        // The transcripts are gone either way; a stale index entry is a lesser
        // problem than a silent one, so it is still reported.
        failures.add(
          CliDeleteFailure(label: '$cli session index', error: error),
        );
      }
    }
    return CliDeleteReport(deleted: deleted, failures: failures);
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

  /// Drops the resume-index entries naming any of [sessionIds], in one listing.
  Future<void> _pruneClaudeIndex(String claudeHome, Set<String> sessionIds) =>
      _removeClaudeIndexEntries(
        claudeHome,
        (entry) => sessionIds.contains(entry['sessionId']),
      );

  Future<void> _removeClaudeIndexEntries(
    String claudeHome,
    bool Function(Map<String, dynamic>) match,
  ) async {
    final indexDir = Directory(p.join(claudeHome, 'sessions'));
    if (!await indexDir.exists()) return;
    storeScans++;
    await for (final entity in indexDir.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      indexEntriesRead++;
      final Object? decoded;
      try {
        decoded = jsonDecode(await entity.readAsString());
      } on Object {
        continue; // Not an entry this app can judge; a delete that fails is reported.
      }
      if (decoded is Map<String, dynamic> && match(decoded)) {
        await entity.delete();
        indexWrites++;
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

  // --- Codex ----------------------------------------------------------------

  /// Asks Codex itself to name the thread. `session_index.jsonl` is a mirror
  /// Codex writes and never reads, so writing it there would be overwritten.
  Future<void> _renameCodex(
    DetectedSession session,
    String title,
    CodexAppServers? servers,
  ) async {
    final client = servers?.forEnvironment(
      session.environmentId,
      storeHome: session.storeHome,
    );
    if (client == null) {
      _log.warning('No Codex to rename ${session.sessionId} in');
      return;
    }
    try {
      final result = await client.setThreadName(session.sessionId, title);
      if (!result.ok) {
        _log.warning(
          'Codex would not rename ${session.sessionId}: ${result.failure}',
        );
      }
    } catch (error) {
      _log.warning(
        'Could not reach Codex to rename ${session.sessionId}',
        error,
      );
    }
  }

  /// Drops the index entries naming any of [sessionIds] — one read, one write.
  Future<void> _pruneCodexIndex(
    String codexHome,
    Set<String> sessionIds,
  ) async {
    final index = File(p.join(codexHome, 'session_index.jsonl'));
    if (!await index.exists()) return;
    storeScans++;
    final lines = await _readIndexLines(index);
    indexEntriesRead += lines.length;
    final out = [
      for (final line in lines)
        if (!sessionIds.contains(_tryDecode(line)?['id'])) line,
    ];
    await index.writeAsString(out.isEmpty ? '' : '${out.join('\n')}\n');
    indexWrites++;
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

  // --- Antigravity ----------------------------------------------------------

  Future<void> _renameAntigravity(DetectedSession session, String title) async {
    final annotationsDir = Directory(p.join(session.storeHome, 'annotations'));
    if (!await annotationsDir.exists()) {
      await annotationsDir.create(recursive: true);
    }
    final file = File(
      p.join(annotationsDir.path, '${session.sessionId}.pbtxt'),
    );
    final escaped = _escapeProtobufString(title);
    await file.writeAsString('title:"$escaped"\n');
    indexWrites++;

    final summariesPath = p.join(
      session.storeHome,
      'conversation_summaries.db',
    );
    if (await File(summariesPath).exists()) {
      Database? db;
      try {
        db = sqlite3.open(summariesPath);
        db.execute(
          'UPDATE conversation_summaries SET title = ? WHERE conversation_id = ?',
          [title, session.sessionId],
        );
        indexWrites++;
      } finally {
        db?.close();
      }
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

  Future<void> _pruneAntigravityIndex(
    String storeHome,
    Set<String> sessionIds,
  ) async {
    storeScans++;
    for (final id in sessionIds) {
      for (final path in [
        p.join(storeHome, 'annotations', '$id.pbtxt'),
        p.join(storeHome, 'presence', '$id.lock'),
      ]) {
        final file = File(path);
        if (await file.exists()) {
          await file.delete();
          indexWrites++;
        }
      }
    }

    final summariesPath = p.join(storeHome, 'conversation_summaries.db');
    if (await File(summariesPath).exists()) {
      Database? db;
      try {
        db = sqlite3.open(summariesPath);
        for (final id in sessionIds) {
          db.execute(
            'DELETE FROM conversation_summaries WHERE conversation_id = ?',
            [id],
          );
        }
        indexWrites++;
      } finally {
        db?.close();
      }
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
          if (sessionIds.contains(entry.value.toString())) {
            updated.remove(entry.key);
            modified = true;
          }
        }
        if (modified) {
          await lastConvFile.writeAsString(jsonEncode(updated));
          indexWrites++;
        }
      }
    }
  }
}
