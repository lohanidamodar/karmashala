import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../../../core/logging/app_logger.dart';
import '../../agents/domain/agent_ids.dart';
import '../domain/detected_session.dart';
import 'codex_app_servers.dart';

/// What a batched delete could not remove, in the words a notification uses.
///
/// [label] is a session's own title, or the store index when a whole group's
/// index could not be rewritten — so the report reads as a list of things left
/// behind rather than as a stack trace.
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

/// Renames and deletes detected CLI sessions, matching what each CLI itself
/// does (ported from the reference Karmashala CLI):
///
/// * **Claude** rename appends a `{"type":"custom-title",…}` line (what
///   `/rename` writes); delete removes the `.jsonl` and any `~/.claude/sessions`
///   resume-index entry.
/// * **Codex** rename asks the running CLI, over its app-server, to do it —
///   see [_renameCodex] for why the file this used to write is the wrong place.
///   Delete still edits `<codexHome>/session_index.jsonl` and removes the
///   rollout file.
class CliSessionMutator {
  CliSessionMutator();

  static final _log = AppLogger.named('cli.sessionMutator');

  /// **What a delete actually costs the store.** Counted rather than timed, the
  /// same way `ClaudeStoreReader.bytesRead` is: the unit that matters here is
  /// index work, and it is countable directly.
  ///
  /// [storeScans] is the number of times a whole store index was walked or
  /// read; [indexEntriesRead] the records decoded out of one; [indexWrites] the
  /// index files rewritten; [transcriptsDeleted] the session files removed.
  int storeScans = 0;
  int indexEntriesRead = 0;
  int indexWrites = 0;
  int transcriptsDeleted = 0;

  /// Renames one session in its CLI's own store.
  ///
  /// [codex] is how a Codex rename reaches the CLI that owns the name; without
  /// one only the mirror file can be updated, which Codex does not read.
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

  /// Deletes one session, throwing if it could not be removed.
  ///
  /// The single-session form of [deleteAll], and implemented as one so the two
  /// cannot come to treat a store differently.
  Future<void> delete(DetectedSession session) async {
    final report = await deleteAll([session]);
    final failure = report.failures.firstOrNull;
    if (failure != null) throw failure.error;
  }

  /// Deletes every session in [sessions], **walking each store's index once**
  /// rather than once per session.
  ///
  /// That is the whole point of the batch. Deleting one Claude session lists
  /// `<claudeHome>/sessions` and decodes every entry in it; deleting one Codex
  /// session reads, decodes and rewrites the whole `session_index.jsonl`. Done
  /// per session that is quadratic in the size of the store — 33 sessions out
  /// of the owner's workspace decoded 289 index records and rewrote the Codex
  /// index 33 times. Grouped, it is one pass per store.
  ///
  /// **Never throws.** A transcript that could not be deleted, or an index that
  /// could not be rewritten, comes back in the report so the caller can tell
  /// the user what was left behind — and so one bad file cannot abandon the
  /// rest of the batch. This is the one operation in the app that reaches
  /// outside it irreversibly, so what it did and what it could not do are
  /// reported rather than inferred.
  Future<CliDeleteReport> deleteAll(Iterable<DetectedSession> sessions) async {
    final groups = <(String, String), List<DetectedSession>>{};
    for (final session in sessions) {
      groups.putIfAbsent((session.cli, session.storeHome), () => []).add(session);
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
  Future<void> _pruneClaudeIndex(
    String claudeHome,
    Set<String> sessionIds,
  ) => _removeClaudeIndexEntries(
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
      try {
        final decoded = jsonDecode(await entity.readAsString());
        if (decoded is Map<String, dynamic> && match(decoded)) {
          await entity.delete();
          indexWrites++;
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

  /// Asks Codex itself to name the thread, and only falls back to the file.
  ///
  /// **`session_index.jsonl` is a derived mirror Codex writes and never reads.**
  /// Established by planting a sentinel in it under a scratch `CODEX_HOME`:
  /// `thread/list` ignored it (with `useStateDbOnly` either way) and left it
  /// untouched, while a sentinel planted in `state_5.sqlite`'s `threads.name`
  /// *was* returned. So the rewrite this method used to do looked right locally
  /// and was overwritten by Codex's next naming event — the reported bug.
  ///
  /// `thread/name/set` is the authoritative write. Verified round-trip against
  /// the owner's own store: it answered `{}`, `threads.name` held the new name,
  /// **and** a fresh `session_index.jsonl` line was appended — so the file-based
  /// read path stays correct without this method touching the file.
  ///
  /// Best-effort throughout. The local rename is already applied and on screen;
  /// a Codex that is not installed, not reachable or too old must not undo it.
  ///
  /// The file write survives only for callers that supply no [servers] — there
  /// is one left, `DetectedProjectsController.renameSession` — and for a Codex
  /// that could not be reached. It keeps *our* view of the name consistent until
  /// Codex has an opinion of its own; it is the whole method's fallback, not its
  /// path, and it goes when the last unwired caller is wired.
  Future<void> _renameCodex(
    DetectedSession session,
    String title,
    CodexAppServers? servers,
  ) async {
    final client = servers?.forEnvironment(
      session.environmentId,
      storeHome: session.storeHome,
    );
    if (client != null) {
      try {
        final result = await client.setThreadName(session.sessionId, title);
        if (result.ok) return;
        _log.warning(
          'Codex would not rename ${session.sessionId}: ${result.failure}',
        );
      } catch (error) {
        _log.warning('Could not reach Codex to rename ${session.sessionId}', error);
      }
    }
    await _mirrorCodexName(session, title);
  }

  /// Writes [title] into the derived index, stamped now.
  ///
  /// Every historical line for the id used to be rewritten while keeping its own
  /// stale `updated_at`, which falsified the name history, and an entry appended
  /// for an unknown id carried no `updated_at` at all. Only the newest line is
  /// touched now, and both paths are stamped — matching the fresh line Codex
  /// itself appends.
  Future<void> _mirrorCodexName(DetectedSession session, String title) async {
    // A row that never came off disk carries no store home, and there is
    // nothing to mirror into.
    if (session.storeHome.isEmpty) return;
    final index = _codexIndex(session);
    final lines = await _readIndexLines(index);
    final stamp = DateTime.now().toUtc().toIso8601String();
    var newest = -1;
    for (var i = 0; i < lines.length; i++) {
      if (_tryDecode(lines[i])?['id'] == session.sessionId) newest = i;
    }
    final out = [...lines];
    final entry = newest < 0 ? null : _tryDecode(out[newest]);
    final named = jsonEncode({
      ...?entry,
      'id': session.sessionId,
      'thread_name': title,
      'updated_at': stamp,
    });
    if (newest < 0) {
      out.add(named);
    } else {
      out[newest] = named;
    }
    await index.writeAsString('${out.join('\n')}\n');
    indexWrites++;
  }

  /// Drops the index entries naming any of [sessionIds] — one read, one write.
  Future<void> _pruneCodexIndex(String codexHome, Set<String> sessionIds) async {
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
    final file = File(p.join(annotationsDir.path, '${session.sessionId}.pbtxt'));
    final escaped = _escapeProtobufString(title);
    await file.writeAsString('title:"$escaped"\n');
    indexWrites++;

    final summariesPath = p.join(session.storeHome, 'conversation_summaries.db');
    if (await File(summariesPath).exists()) {
      Database? db;
      try {
        db = sqlite3.open(summariesPath);
        db.execute(
          'UPDATE conversation_summaries SET title = ? WHERE conversation_id = ?',
          [title, session.sessionId],
        );
        indexWrites++;
      } catch (_) {
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
      try {
        final annotation = File(p.join(storeHome, 'annotations', '$id.pbtxt'));
        if (await annotation.exists()) {
          await annotation.delete();
          indexWrites++;
        }
      } catch (_) {}
      try {
        final presence = File(p.join(storeHome, 'presence', '$id.lock'));
        if (await presence.exists()) {
          await presence.delete();
          indexWrites++;
        }
      } catch (_) {}
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
      } catch (_) {
      } finally {
        db?.close();
      }
    }

    final lastConvPath = p.join(storeHome, 'cache', 'last_conversations.json');
    final lastConvFile = File(lastConvPath);
    if (await lastConvFile.exists()) {
      try {
        final raw = await lastConvFile.readAsString();
        final map = jsonDecode(raw);
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
      } catch (_) {}
    }
  }
}
