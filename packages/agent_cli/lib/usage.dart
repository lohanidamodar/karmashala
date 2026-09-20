/// **Mode 5 — what an agent has spent, and who is signed in.**
///
/// Token and rate-limit accounting read out of each CLI's own files —
/// Claude Code's `stats-cache.json`, Codex's rollouts and thread index,
/// Antigravity's store — plus the account each CLI is authenticated as, the
/// throttle that keeps a refresh from costing more than the number is worth,
/// and what a history of readings says about a window: the pace it is being
/// spent at, and what each local day cost.
library;

export 'src/agents/data/agent_usage_service.dart';
export 'src/agents/data/claude_auth_service.dart';
export 'src/agents/data/credential_push.dart';
export 'src/agents/data/codex_auth_service.dart';
export 'src/agents/data/usage_throttle.dart';
export 'src/agents/domain/agent_usage.dart';
export 'src/agents/domain/claude_account.dart';
export 'src/agents/domain/claude_auth_snapshot.dart';
export 'src/agents/domain/codex_account.dart';
export 'src/agents/domain/usage_failure.dart';
export 'src/agents/domain/usage_pace.dart';
export 'src/agents/domain/usage_sample.dart';
export 'src/cli_detection/data/agent_lifetime_reader.dart';
export 'src/cli_detection/data/codex_rate_limit_reader.dart';
export 'src/cli_detection/data/codex_stats_reader.dart';
export 'src/cli_detection/domain/session_stats.dart';
