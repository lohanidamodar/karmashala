import '../../util/sqlite_rows.dart';
import '../adapter/agent_stats.dart';
import 'claude_lifetime_reader.dart';
import 'claude_store_reader.dart';

/// Claude Code's accounting: a session's totals from its transcript, the
/// lifetime totals from the cache its `/stats` screen keeps.
class ClaudeCodeStats implements AgentStats {
  const ClaudeCodeStats();

  @override
  SessionStatsReader sessionStatsReader() => ClaudeStoreReader();

  @override
  LifetimeStatsReader lifetimeReader({required SqliteRowReader readRows}) =>
      ClaudeLifetimeReader();
}
