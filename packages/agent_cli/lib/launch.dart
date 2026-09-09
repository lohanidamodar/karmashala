/// **Mode 1 — the argv for an interactive session.**
///
/// What a host puts in a terminal pane: the command line that starts a CLI in
/// its own TUI, resumes a conversation, picks a model, sets a permission mode.
/// Nothing here spawns anything — these are pure functions over a descriptor
/// and an `AgentLaunch`, so the command line can be asserted in a test.
library;

export 'src/agents/data/antigravity_adapter.dart'
    show antigravityLaunchArgs, parseAntigravityMessage;
export 'src/agents/data/claude_code_adapter.dart'
    show claudeLaunchArgs, parseClaudeMessage, encodeClaudeUserMessage;
export 'src/agents/data/codex_adapter.dart'
    show codexLaunchArgs, parseCodexMessage, encodeCodexUserMessage;
export 'src/agents/data/generic_agent_adapter.dart'
    show genericLaunchArgs, parseGenericAgentLine;
export 'src/agents/domain/agent_adapter.dart' show AgentLaunch;
export 'src/cli_detection/domain/agent_command_line.dart';
