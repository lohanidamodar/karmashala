import '../../util/sqlite_rows.dart';
import '../adapter/agent_stats.dart';
import 'codex_lifetime_reader.dart';
import 'codex_stats_reader.dart';

/// Codex's accounting: a session's totals from its rollout, the lifetime
/// totals from the thread index it keeps as it runs.
class CodexStats implements AgentStats {
  const CodexStats();

  @override
  SessionStatsReader sessionStatsReader() => CodexStatsReader();

  @override
  LifetimeStatsReader lifetimeReader({required SqliteRowReader readRows}) =>
      CodexLifetimeReader(readRows: readRows);
}
