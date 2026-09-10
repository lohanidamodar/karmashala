import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/descriptors.dart';

/// Derives an agent's status from its own state file: a bounded **tail** rather
/// than the whole file, and anything unmatched is `unknown`, not a guess.
class AgentStateFileStatusSource {
  const AgentStateFileStatusSource({this.tailBytes = 65536});

  /// How much of the file's end to read when looking for the last record.
  final int tailBytes;

  /// How many earlier records a walking agent keeps. Eight: of the owner's 52
  /// Codex rollouts, 48 need no walk at all and the rest need three or four.
  static const int earlierRecordsKept = 8;

  /// How much of those records' text to keep. Raw lines, decoded only if the
  /// last record says nothing, so the usual walk costs these bytes and no CPU.
  static const int earlierBytesKept = 8192;

  /// Reads [filePath] and classifies it, or returns `null` when there is
  /// nothing to say (no rules for this agent, or no readable record).
  Future<AgentStatusReport?> read(
    AgentDescriptor descriptor,
    String filePath,
    DateTime now, {
    String sessionId = '',
  }) async {
    if (descriptor.stateFile == null) return null;
    final snapshot = await probe(filePath);
    if (snapshot == null) return null;
    return classify(descriptor, snapshot, now, sessionId: sessionId);
  }

  /// Stats [filePath] and re-reads its tail only when it changed since [known],
  /// so a quiet transcript costs one `stat`. `null` if missing or unreadable.
  Future<StateFileSnapshot?> probe(
    String filePath, {
    StateFileSnapshot? known,
  }) async {
    final file = File(filePath);
    try {
      final stat = await file.stat();
      if (stat.type == FileSystemEntityType.notFound) return null;
      final modified = stat.modified;
      if (known != null &&
          known.modified == modified &&
          known.size == stat.size) {
        return known;
      }
      final tail = await _readTail(file, stat.size);
      return StateFileSnapshot(
        modified: modified,
        size: stat.size,
        record: lastJsonRecord(tail),
        earlierLines: earlierJsonLines(tail),
      );
    } on FileSystemException {
      return null;
    }
  }

  /// Classifies an already-read [snapshot]. Pure, and [now] is applied here, so
  /// a cached snapshot's stale `working` still ages into `unknown` on its own.
  AgentStatusReport? classify(
    AgentDescriptor descriptor,
    StateFileSnapshot snapshot,
    DateTime now, {
    String sessionId = '',
  }) {
    final rules = descriptor.stateFile;
    if (rules == null) return null;
    final record = snapshot.record;
    if (record == null) return null;

    final matched =
        _classify(rules, record, snapshot.modified, now) ??
        _classifyEarlier(rules, snapshot, now);
    final (status, detail) = matched ?? (AgentActivityStatus.unknown, null);
    return AgentStatusReport(
      agentId: descriptor.id,
      sessionId: sessionId,
      status: status,
      source: AgentStatusSource.stateFile,
      observedAt: now,
      // The file's own mtime, not the poll's: a transcript nothing has touched
      // for a day must not read as a fresh observation.
      sourceModifiedAt: snapshot.modified,
      detail: detail,
    );
  }

  /// The first of [snapshot]'s earlier records that any rule matches, decoded
  /// here rather than in [probe] so the usual session never pays for it.
  (AgentActivityStatus, String?)? _classifyEarlier(
    AgentStateFileRules rules,
    StateFileSnapshot snapshot,
    DateTime now,
  ) {
    if (!rules.looksPastUnclassifiedRecords) return null;
    for (final line in snapshot.earlierLines) {
      final record = _decodeObject(line);
      if (record == null) continue;
      final matched = _classify(rules, record, snapshot.modified, now);
      if (matched != null) return matched;
    }
    return null;
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

  /// What [record] says, or `null` when no rule matched. A stale `working` is
  /// still a **match**, so the walk stops rather than reaching an older `idle`.
  (AgentActivityStatus, String?)? _classify(
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

    // **Working before idle**: one record can satisfy both, and a Claude Code
    // tool call is an assistant record carrying an unanswered `tool_use` block.
    final working = _firstMatch(rules.working, record);
    if (working != null) {
      // An in-progress record only means "working" while the file is still
      // being written; it ages into `unknown`, which cannot fire a completion.
      final since = now.difference(modified);
      return since <= rules.activityWindow
          ? (AgentActivityStatus.working, working)
          : (AgentActivityStatus.unknown, 'stale: $working');
    }

    final idle = _firstMatch(rules.idle, record);
    if (idle != null) return (AgentActivityStatus.idle, idle);

    return null;
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

/// One reading of a state file's end: what it said, and how to tell whether it
/// has changed since.
class StateFileSnapshot {
  const StateFileSnapshot({
    required this.modified,
    required this.size,
    required this.record,
    this.earlierLines = const [],
  });

  final DateTime modified;
  final int size;

  /// The last decodable record, or `null` when the file held none.
  final Map<String, Object?>? record;

  /// The raw lines immediately before [record], newest first and bounded. Text,
  /// because this is held per tracked session and usually never read.
  final List<String> earlierLines;
}

/// The last line of [tail] that decodes to a JSON object, or `null`. Walked
/// backwards, so a half-written final line is skipped rather than fatal.
Map<String, Object?>? lastJsonRecord(String tail) {
  final lines = tail.split('\n');
  for (var i = lines.length - 1; i >= 0; i--) {
    final line = lines[i].trim();
    if (line.isEmpty) continue;
    final decoded = _decodeObject(line);
    if (decoded != null) return decoded;
  }
  return null;
}

/// The lines of [tail] before the one [lastJsonRecord] returned, newest first.
/// Bounded by count and bytes; running out stops the walk, leaving `unknown`.
List<String> earlierJsonLines(String tail) {
  final lines = tail.split('\n');
  final kept = <String>[];
  var budget = AgentStateFileStatusSource.earlierBytesKept;
  var foundLast = false;
  for (var i = lines.length - 1; i >= 0; i--) {
    final line = lines[i].trim();
    if (line.isEmpty) continue;
    if (!foundLast) {
      foundLast = _decodeObject(line) != null;
      continue;
    }
    if (kept.length >= AgentStateFileStatusSource.earlierRecordsKept) break;
    if (line.length > budget) break;
    budget -= line.length;
    kept.add(line);
  }
  return kept;
}

/// [line] decoded as a JSON object, or `null` if it is neither.
Map<String, Object?>? _decodeObject(String line) {
  try {
    final decoded = jsonDecode(line);
    return decoded is Map<String, Object?> ? decoded : null;
  } on FormatException {
    return null;
  }
}
