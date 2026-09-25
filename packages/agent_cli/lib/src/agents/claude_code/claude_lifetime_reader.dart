import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../cli_detection/domain/session_stats.dart';
import '../adapter/agent_stats.dart';

/// Claude Code's own lifetime totals, from the cache its `/stats` screen keeps.
///
/// `<claudeHome>/stats-cache.json`, and its real shape on this machine:
///
/// ```json
/// { "version": 2, "lastComputedDate": "2026-02-24",
///   "dailyActivity":    [{ "date", "messageCount", "sessionCount", "toolCallCount" }],
///   "dailyModelTokens": [{ "date", "tokensByModel": { "<model>": n } }],
///   "modelUsage": { "<model>": { "inputTokens", "outputTokens",
///                                "cacheReadInputTokens", "cacheCreationInputTokens",
///                                "webSearchRequests", "costUSD",
///                                "contextWindow", "maxOutputTokens" } },
///   "totalSessions", "totalMessages",
///   "longestSession": { "sessionId", "duration", "messageCount", "timestamp" },
///   "firstSessionDate", "hourCounts": { "<hour>": n },
///   "totalSpeculationTimeSavedMs" }
/// ```
///
/// Three properties of this file decide how it may be shown:
///
/// * **It is a cache, and it can be very stale.** It is rewritten when the
///   CLI's own stats screen runs, not as sessions happen. On this machine
///   `lastComputedDate` is `2026-02-24` and the file was last touched the day
///   after — **189 days ago** — while it claims `totalSessions: 1` against 38
///   session files sitting in the store beside it. So [LifetimeStats.computedAt]
///   is not decoration: without it these numbers read as current and they are
///   not.
/// * **It is per config directory, not per account.** It carries no account id;
///   the signed-in account lives separately in `.claude.json` (`oauthAccount`,
///   `machineID`). Switching Claude accounts keeps writing the same file.
/// * **`costUSD` is in there and is deliberately not read.** No dollar figures
///   anywhere in this feature.
///
/// Only the explicit totals are used. `dailyActivity` and `dailyModelTokens`
/// are per-day series that a cache is free to trim, so deriving a lifetime tool
/// count from them would be a total over whatever window happened to survive.
class ClaudeLifetimeReader implements LifetimeStatsReader {
  ClaudeLifetimeReader({ClaudeLifetimeCache? cache})
    : _cache = cache ?? ClaudeLifetimeCache.shared;

  final ClaudeLifetimeCache _cache;

  /// Bytes pulled off the disk. The file is about a kilobyte, but the rule is
  /// the same as everywhere else here: reading it twice reads it once.
  int bytesRead = 0;

  /// Null when there is no cache file to read.
  @override
  Future<LifetimeStats?> read(String claudeHome) async {
    final file = File(p.join(claudeHome, 'stats-cache.json'));
    final FileStat stat;
    try {
      stat = await file.stat();
    } on Object {
      return null;
    }
    if (stat.type == FileSystemEntityType.notFound) return null;

    final cached = _cache._byPath[file.path];
    if (cached != null &&
        cached.size == stat.size &&
        cached.modified == stat.modified) {
      return cached.stats;
    }

    final String source;
    try {
      source = await file.readAsString();
    } on Object {
      return null;
    }
    bytesRead += source.length;

    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, dynamic>) return null;

    var input = 0, output = 0, cacheCreated = 0, cacheRead = 0;
    var sawUsage = false;
    final usage = decoded['modelUsage'];
    if (usage is Map) {
      for (final model in usage.values) {
        if (model is! Map) continue;
        sawUsage = true;
        input += _int(model['inputTokens']) ?? 0;
        output += _int(model['outputTokens']) ?? 0;
        cacheCreated += _int(model['cacheCreationInputTokens']) ?? 0;
        cacheRead += _int(model['cacheReadInputTokens']) ?? 0;
      }
    }
    final tokens = sawUsage
        ? TokenTally(
            input: input,
            output: output,
            cacheCreated: cacheCreated,
            cacheRead: cacheRead,
          )
        : TokenTally.unknown;

    final stats = LifetimeStats(
      source: LifetimeStatsSource.agentCache,
      sessions: _int(decoded['totalSessions']),
      messages: _int(decoded['totalMessages']),
      tokens: tokens,
      totalTokens: tokens.total,
      // The date the CLI stamped, not the file's mtime — the stamp is what the
      // CLI believes it computed, and the mtime only says when it was flushed.
      computedAt: _date(decoded['lastComputedDate']) ?? stat.modified,
      firstActivityAt: _date(decoded['firstSessionDate']),
      note:
          'Claude Code counts whole messages here, its own and its tools\u2019 '
          'replies together \u2014 not the turns and replies counted above.',
    );

    _cache._byPath[file.path] = _ClaudeLifetimeEntry(
      size: stat.size,
      modified: stat.modified,
      stats: stats,
    );
    return stats;
  }
}

class ClaudeLifetimeCache {
  ClaudeLifetimeCache();

  static final ClaudeLifetimeCache shared = ClaudeLifetimeCache();

  final Map<String, _ClaudeLifetimeEntry> _byPath = {};

  int get length => _byPath.length;

  void clear() => _byPath.clear();
}

class _ClaudeLifetimeEntry {
  const _ClaudeLifetimeEntry({
    required this.size,
    required this.modified,
    required this.stats,
  });

  final int size;
  final DateTime modified;
  final LifetimeStats stats;
}

int? _int(Object? value) => value is num ? value.toInt() : null;

/// A whole-day stamp (`2026-02-24`) or an instant (`…T09:41:48.537Z`).
///
/// **Not forced to UTC.** `lastComputedDate` is a calendar day the CLI stamped
/// in the user's own timezone, and converting it moves it: east of Greenwich
/// "2026-02-24" becomes the 23rd, and the dialog would report the cache as a
/// day older than it is. `DateTime.tryParse` already returns UTC for a stamp
/// that carries a zone and local time for a bare date, which is exactly right
/// for both.
DateTime? _date(Object? value) {
  if (value is! String || value.isEmpty) return null;
  return DateTime.tryParse(value);
}
