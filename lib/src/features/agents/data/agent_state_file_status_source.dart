import 'dart:convert';
import 'dart:io';

import '../domain/agent_descriptor.dart';
import '../domain/agent_status.dart';

/// Derives an agent's status from its own session/state file.
///
/// This deliberately reuses what CLI detection already knows: the transcript's
/// path comes from `DetectedSession`/`ImportedSession`, which the store readers
/// produced. Only the classification is new, and it reads a bounded **tail**
/// rather than re-parsing the whole file — a status poll must stay cheap.
///
/// Classification is data, not code: each agent's [AgentStateFileRules] say
/// which record shapes mean what. Anything unmatched is `unknown`, never a
/// guess.
class AgentStateFileStatusSource {
  const AgentStateFileStatusSource({this.tailBytes = 65536});

  /// How much of the file's end to read when looking for the last record.
  final int tailBytes;

  /// Reads [filePath] and classifies it, or returns `null` when there is
  /// nothing to say (no rules for this agent, or no readable record).
  Future<AgentStatusReport?> read(
    AgentDescriptor descriptor,
    String filePath,
    DateTime now, {
    String sessionId = '',
  }) async {
    final rules = descriptor.stateFile;
    if (rules == null) return null;

    final file = File(filePath);
    final DateTime modified;
    final String tail;
    try {
      final stat = await file.stat();
      if (stat.type == FileSystemEntityType.notFound) return null;
      modified = stat.modified;
      tail = await _readTail(file, stat.size);
    } on FileSystemException {
      return null;
    }

    final record = lastJsonRecord(tail);
    if (record == null) return null;

    final (status, detail) = _classify(rules, record, modified, now);
    return AgentStatusReport(
      agentId: descriptor.id,
      sessionId: sessionId,
      status: status,
      source: AgentStatusSource.stateFile,
      observedAt: now,
      // The file's own mtime, not the poll's: a transcript nothing has touched
      // for a day must not read as a fresh observation.
      sourceModifiedAt: modified,
      detail: detail,
    );
  }

  Future<String> _readTail(File file, int size) async {
    final start = size > tailBytes ? size - tailBytes : 0;
    final handle = await file.open();
    try {
      await handle.setPosition(start);
      final bytes = await handle.read(size - start);
      // Lossy on purpose: the window can start mid-character, and that line is
      // discarded anyway.
      return const Utf8Decoder(allowMalformed: true).convert(bytes);
    } finally {
      await handle.close();
    }
  }

  (AgentActivityStatus, String?) _classify(
    AgentStateFileRules rules,
    Map<String, Object?> record,
    DateTime modified,
    DateTime now,
  ) {
    final failed = _firstMatch(rules.failed, record);
    if (failed != null) return (AgentActivityStatus.failed, failed);

    final approval = _firstMatch(rules.awaitingApproval, record);
    if (approval != null) {
      return (AgentActivityStatus.awaitingApproval, approval);
    }

    final idle = _firstMatch(rules.idle, record);
    if (idle != null) return (AgentActivityStatus.idle, idle);

    final working = _firstMatch(rules.working, record);
    if (working != null) {
      // An in-progress record only means "working" while the file is still
      // being written; otherwise the CLI exited mid-turn and we cannot say.
      final since = now.difference(modified);
      return since <= rules.activityWindow
          ? (AgentActivityStatus.working, working)
          : (AgentActivityStatus.unknown, 'stale: $working');
    }
    return (AgentActivityStatus.unknown, null);
  }

  String? _firstMatch(
    List<StateRecordMatcher> matchers,
    Map<String, Object?> record,
  ) {
    for (final matcher in matchers) {
      if (matcher.matches(record)) return matcher.toString();
    }
    return null;
  }
}

/// The last line of [tail] that decodes to a JSON object, or `null`.
///
/// Walking backwards means a truncated or half-written final line is skipped
/// rather than losing the record before it.
Map<String, Object?>? lastJsonRecord(String tail) {
  final lines = tail.split('\n');
  for (var i = lines.length - 1; i >= 0; i--) {
    final line = lines[i].trim();
    if (line.isEmpty) continue;
    try {
      final decoded = jsonDecode(line);
      if (decoded is Map<String, Object?>) return decoded;
    } on FormatException {
      continue;
    }
  }
  return null;
}
