import '../../cli_detection/domain/session_stats.dart';
import '../../util/sqlite_rows.dart';

/// Reads one session's accounting from its transcript.
abstract interface class SessionStatsReader {
  /// The session recorded at [transcriptPath], or null when it cannot be read.
  Future<SessionStats?> readSessionStats(String transcriptPath);
}

/// Reads an agent's own running totals from its store home.
abstract interface class LifetimeStatsReader {
  /// The totals under [storeHome], or null when the source is not there.
  Future<LifetimeStats?> read(String storeHome);
}

/// **Token and turn accounting read from an agent's own records.**
///
/// Readers rather than answers, because they carry the incremental caches that
/// keep a second read proportional to what changed: a caller keeps one reader
/// per agent for its whole life.
abstract interface class AgentStats {
  SessionStatsReader sessionStatsReader();

  /// [readRows] is the host's SQLite binding, for totals kept in a database.
  LifetimeStatsReader lifetimeReader({required SqliteRowReader readRows});
}
