import 'dart:io';

import 'package:path/path.dart' as p;

import '../../cli_detection/domain/session_stats.dart';
import '../../util/sqlite_rows.dart';
import '../adapter/agent_stats.dart';

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
class CodexLifetimeReader implements LifetimeStatsReader {
  const CodexLifetimeReader({this.readRows = noSqliteBinding});

  /// How to read Codex's own thread index. Defaults to no binding at all — see
  /// [SqliteRowReader] for why this package takes none.
  final SqliteRowReader readRows;

  /// Null when there is no readable thread index.
  ///
  /// Uncached on purpose: the CLI writes this database while it runs, and with
  /// a write-ahead log the main file's mtime is not evidence that nothing
  /// changed. One aggregate query over a few dozen rows is cheaper than being
  /// wrong about it.
  @override
  Future<LifetimeStats?> read(String codexHome) async {
    final path = await _newestStateFile(codexHome);
    if (path == null) return null;

    final rows = await readRows(
      path,
      'select count(*) as n, min(created_at) as first, '
      'max(updated_at) as last from threads',
    );
    if (rows == null || rows.isEmpty) return null;
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

DateTime? _unixSeconds(Object? value) {
  final seconds = _int(value);
  if (seconds == null || seconds <= 0) return null;
  return DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
}
