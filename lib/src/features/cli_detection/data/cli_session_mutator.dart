import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../agents/domain/agent_ids.dart';
import '../domain/detected_session.dart';

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

/// Renames and deletes detected CLI sessions on disk, matching what each CLI
/// itself does (ported from the reference Karmashala CLI):
///
/// * **Claude** rename appends a `{"type":"custom-title",…}` line (what
///   `/rename` writes); delete removes the `.jsonl` and any `~/.claude/sessions`
///   resume-index entry.
/// * **Codex** rename/delete edit the `thread_name` / entry in
///   `<codexHome>/session_index.jsonl`; delete also removes the rollout file.
class CliSessionMutator {
  CliSessionMutator();

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

  Future<void> rename(DetectedSession session, String newTitle) {
    final title = newTitle.trim();
    if (title.isEmpty) {
      throw ArgumentError('Title cannot be empty');
    }
    return session.cli == AgentIds.codex
        ? _renameCodex(session, title)
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
        await (cli == AgentIds.codex
            ? _pruneCodexIndex(storeHome, removed)
            : _pruneClaudeIndex(storeHome, removed));
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
}
