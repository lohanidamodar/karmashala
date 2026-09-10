/// The command line one agent launch is handed, per agent.
///
/// A library of its own rather than a `part` of the launcher: a pure function
/// of a descriptor and a set of choices, reading no state, called from both
/// surface starters and from the terminal layer's own tests. **Order is the
/// whole of it**, and it is the order the shipped agents want, not a tidy one.
library;

import 'package:agent_cli/descriptors.dart';
import 'session_mcp_arguments.dart';

/// The interactive command-line arguments for one agent launch, shared by the
/// pane and external-terminal surfaces so the two cannot drift.
///
/// Order matters and is the order the shipped agents want: the MCP flag, then
/// global flags, then the session-id flag, then the resume convention (which
/// for Codex is a *subcommand* and must follow the globals), then the prompt in
/// whichever shape [AgentPromptSupport] names. [forkSessionId] **replaces** the
/// resume convention rather than adding to it — Codex forks with a `fork`
/// subcommand instead of `resume`, while Claude's fork is its own resume plus
/// `--fork-session`, so both shapes come out of one call.
List<String> agentPaneArguments(
  AgentDescriptor? descriptor,
  PermissionSelection permissionMode, {
  String? modelId,
  String? sessionId,
  String? resumeSessionId,
  String? forkSessionId,
  String? prompt,
  String? systemPromptFilePath,
  String? mcpUrl,
  String? mcpConfigPath,
}) {
  final launch = descriptor?.launch;
  final trimmedPrompt = prompt?.trim();
  final forking = forkSessionId != null && forkSessionId.isNotEmpty;
  return [
    // First, because Codex's `-c` is a global option and its resume is a
    // *subcommand*: everything global has to be on the left of it. Nothing here
    // is variadic, so nothing downstream can be swallowed.
    ...agentMcpArguments(descriptor, url: mcpUrl, configPath: mcpConfigPath),
    ...?launch?.permission.argumentsFor(permissionMode),
    // Beside the permission flags and for the same reason: a global option, so
    // it has to be left of Codex's `resume`/`fork` subcommand.
    ...?launch?.model.argumentsFor(modelId),
    // A global too: the file is context for the whole session rather than
    // something the resume or the prompt carries. Nothing is emitted for an
    // agent that takes none, so a packet aimed at one stays in the prompt.
    ...?launch?.systemPromptFile.argumentsFor(systemPromptFilePath),
    if (sessionId != null && resumeSessionId == null && !forking)
      ...?launch?.sessionIdAssignment.argumentsFor(sessionId),
    if (forking) ...?launch?.fork.argumentsFor(forkSessionId),
    if (!forking && resumeSessionId != null && resumeSessionId.isNotEmpty)
      ...?launch?.interactiveResume.argumentsFor(resumeSessionId),
    // Last, and spread rather than appended: the prompt is a positional for
    // Claude and Codex but two argv entries for Antigravity, and which of those
    // it is belongs to the descriptor.
    if (trimmedPrompt != null) ...?launch?.prompt.argumentsFor(trimmedPrompt),
  ];
}
