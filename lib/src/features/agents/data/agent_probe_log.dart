import 'dart:convert';

import '../../../core/database/app_database.dart';

/// Which `(agent, environment)` pairs this workspace has ever *searched* for.
///
/// An agent with no entry here and no installation row has never been looked
/// for, which is not the same as looked for and not found — and only the first
/// is worth spawning a process for. Without it, discovery is a single scan at
/// workspace creation, which is how `antigravity` shipped in 1.1.4 and went
/// unseen.
///
/// Stored as one JSON object in app metadata rather than a table: it holds
/// single digits of entries, and a schema migration would buy nothing a map
/// cannot answer. Unreadable content reads as "nothing has been probed", which
/// costs one extra sweep and can never suppress one.
class AgentProbeLog {
  const AgentProbeLog(this._db);

  final AppDatabase _db;

  /// The metadata key holding the log.
  static const metadataKey = 'agents_probed';

  /// `agentId -> environmentId -> when it was last searched for`.
  Map<String, Map<String, String>> read() {
    final raw = _db.readMetadata(metadataKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return {
        for (final entry in decoded.entries)
          if (entry.key is String && entry.value is Map)
            entry.key as String: {
              for (final inner in (entry.value as Map).entries)
                if (inner.key is String && inner.value is String)
                  inner.key as String: inner.value as String,
            },
      };
    } on FormatException {
      return {};
    }
  }

  bool hasProbed(String agentId, String environmentId) =>
      read()[agentId]?.containsKey(environmentId) ?? false;

  /// Records that [agentId] was searched for in [environmentId] at [at],
  /// whether or not it was found. A miss is the more valuable of the two: it is
  /// what stops the next launch spawning the same process again.
  void record(String agentId, String environmentId, DateTime at) {
    final log = read();
    final forAgent = {...?log[agentId], environmentId: at.toIso8601String()};
    _db.writeMetadata(metadataKey, jsonEncode({...log, agentId: forAgent}));
  }
}
