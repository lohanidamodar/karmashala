import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../domain/session_stats.dart';

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
class ClaudeLifetimeReader {
  ClaudeLifetimeReader({ClaudeLifetimeCache? cache})
    : _cache = cache ?? ClaudeLifetimeCache.shared;

  final ClaudeLifetimeCache _cache;

  /// Bytes pulled off the disk. The file is about a kilobyte, but the rule is
  /// the same as everywhere else here: reading it twice reads it once.
  int bytesRead = 0;

  /// Null when there is no cache file to read.
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

/// Codex's own lifetime totals, from the thread index it keeps as it runs.
///
/// `<codexHome>/state_<n>.sqlite`, table `threads`: one row per conversation
/// with `created_at`, `updated_at`, `rollout_path` and `tokens_used`. The file
/// name is versioned by schema migration — `state_5.sqlite` today — so the
/// highest-numbered one is taken rather than a name being hardcoded.
///
/// ## Why the token total is counted and then not shown
///
/// `tokens_used` is exactly the rollout's last cumulative `total_tokens`:
/// verified on thread `019fd149…`, where both read **41,611,532**. Summing the
/// column is therefore one aggregate query over 61 rows of a 400 KB file, and
/// nothing like the store sweep it looks like.
///
/// It is still not shown, because **the sum is the number that is known to go
/// wrong**. A Codex subagent's rollout can contain a full replay of its
/// parent's usage history, re-timestamped — the defect behind ccusage #950 and
/// its 91× overcount — and this index is derived from those same rollouts, so a
/// sum over it inherits whatever they say.
///
/// It does not reproduce on this machine: all four subagent-flavoured threads
/// here (two named by `thread_spawn_edges`, two by `thread_source = 'subagent'`
/// — and they are four different threads, so neither marker alone would find
/// them all) open at cumulative totals of 12,949 to 17,052, which is a thread
/// starting from nothing rather than one inheriting a parent's books. But that
/// is a check run once by hand against one store, not something this reader can
/// perform, and a 91×-inflated figure in a dialog whose whole point is
/// trustworthy counts is far worse than a missing one.
///
/// So: the thread count and the dates are reported, because counting rows
/// cannot be inflated by a replay, and the token total is left out with
/// [LifetimeStats.note] saying why.
class CodexLifetimeReader {
  const CodexLifetimeReader();

  /// Null when there is no readable thread index.
  ///
  /// Uncached on purpose: the CLI writes this database while it runs, and with
  /// a write-ahead log the main file's mtime is not evidence that nothing
  /// changed. One aggregate query over a few dozen rows is cheaper than being
  /// wrong about it.
  Future<LifetimeStats?> read(String codexHome) async {
    final path = await _newestStateFile(codexHome);
    if (path == null) return null;

    Database? db;
    try {
      db = sqlite3.open(path, mode: OpenMode.readOnly);
      final rows = db.select(
        'select count(*) as n, min(created_at) as first, '
        'max(updated_at) as last from threads',
      );
      if (rows.isEmpty) return null;
      final row = rows.first;
      final count = _int(row['n']);
      if (count == null) return null;
      return LifetimeStats(
        source: LifetimeStatsSource.agentIndex,
        sessions: count,
        firstActivityAt: _unixSeconds(row['first']),
        lastActivityAt: _unixSeconds(row['last']),
        note:
            'Codex records one running total per thread, and a subagent thread '
            'can replay its parent\u2019s history into its own file \u2014 so '
            'adding them up can inflate the figure badly. The thread count is '
            'safe; the token total is not, so it is not shown.',
      );
    } on SqliteException {
      return null;
    } on Object {
      return null;
    } finally {
      db?.close();
    }
  }

  /// `state_<n>.sqlite` with the highest `<n>`, or null when there is none.
  static Future<String?> _newestStateFile(String codexHome) async {
    final directory = Directory(codexHome);
    if (!await directory.exists()) return null;
    String? best;
    var bestVersion = -1;
    try {
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is! File) continue;
        final match = _stateFile.firstMatch(p.basename(entity.path));
        if (match == null) continue;
        final version = int.tryParse(match.group(1)!) ?? -1;
        if (version > bestVersion) {
          bestVersion = version;
          best = entity.path;
        }
      }
    } on FileSystemException {
      return null;
    }
    return best;
  }
}

final RegExp _stateFile = RegExp(r'^state_(\d+)\.sqlite$');

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

DateTime? _unixSeconds(Object? value) {
  final seconds = _int(value);
  if (seconds == null || seconds <= 0) return null;
  return DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
}
