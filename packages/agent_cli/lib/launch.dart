/// **Mode 1 — the argv for an interactive session.**
///
/// What a host puts in a terminal pane: the command line that starts a CLI in
/// its own TUI, resumes a conversation, picks a model, sets a permission mode.
/// Nothing here spawns anything — these are pure functions over a descriptor
/// and an `AgentLaunch`, so the command line can be asserted in a test.
library;

export 'src/agents/antigravity/antigravity_chat_protocol.dart'
    show antigravityLaunchArgs, parseAntigravityMessage;
export 'src/agents/claude_code/claude_code_chat_protocol.dart'
    show claudeLaunchArgs, parseClaudeMessage, encodeClaudeUserMessage;
export 'src/agents/codex/codex_chat_protocol.dart'
    show codexLaunchArgs, parseCodexMessage, encodeCodexUserMessage;
export 'src/agents/adapter/generic_chat_protocol.dart'
    show genericLaunchArgs, parseGenericAgentLine;
export 'src/agents/adapter/agent_chat_protocol.dart' show AgentLaunch;
export 'src/agents/domain/anthropic_credential_env.dart';
export 'src/cli_detection/domain/agent_command_line.dart';
