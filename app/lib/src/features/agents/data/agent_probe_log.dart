import 'dart:convert';

import 'package:karmashala_store/database.dart';

/// Which `(agent, environment)` pairs this workspace has ever *searched* for —
/// never looked for is not the same as looked for and not found.
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

  /// Records that [agentId] was searched for in [environmentId], found or not.
  /// A miss is the valuable half: it stops the next launch spawning again.
  void record(String agentId, String environmentId, DateTime at) {
    final log = read();
    final forAgent = {...?log[agentId], environmentId: at.toIso8601String()};
    _db.writeMetadata(metadataKey, jsonEncode({...log, agentId: forAgent}));
  }
}
