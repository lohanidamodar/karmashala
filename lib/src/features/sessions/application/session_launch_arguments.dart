/// The command line one agent launch is handed, per agent.
///
/// A library of its own rather than a `part` of the launcher, following
/// `session_mcp_arguments.dart` beside it: this is a pure function of a
/// descriptor and a set of choices, it reads no state and it is called from
/// both of the launcher's surface starters and from the terminal layer's own
/// tests. The launcher re-exports it, which is where every caller already
/// reaches for it.
///
/// **Order is the whole of it**, and it is the order the shipped agents want
/// rather than a tidy one. See the function's own note.
library;

import '../../agents/domain/agent_descriptor.dart';
import '../../agents/domain/agent_permission_support.dart';
import 'session_mcp_arguments.dart';

/// The interactive command-line arguments for one agent launch.
///
/// Shared by the pane and external-terminal surfaces so the two cannot drift:
/// "open this in Windows Terminal instead" must produce the same agent, in the
/// same mode, on the same conversation.
///
/// Order matters and is the order the shipped agents want: the MCP flag, then
/// global flags, then the session-id flag, then the resume convention (which
/// for Codex is a *subcommand* and must follow the globals), then the prompt in
/// whichever shape the descriptor's [AgentPromptSupport] names — a trailing
/// positional for Claude and Codex, a flag and its value for Antigravity.
///
/// [systemPromptFilePath] rides with the globals for the same reason the model
/// flag does, and is the handoff packet's way in for an agent that takes one.
///
/// [forkSessionId] **replaces** the resume convention rather than adding to it:
/// Codex forks with a `fork` subcommand *instead of* `resume`, and emitting
/// both would put two subcommands on one command line. Claude's fork is its own
/// resume plus `--fork-session`, which its [AgentForkSupport] states, so both
/// shapes come out of one call.
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
    // *subcommand*: everything global has to be on the left of it. Nothing
    // here is variadic — Claude's config flag is deliberately one
    // `--flag=value` token — so nothing downstream can be swallowed.
    ...agentMcpArguments(descriptor, url: mcpUrl, configPath: mcpConfigPath),
    ...?launch?.permission.argumentsFor(permissionMode),
    // Beside the permission flags and for the same reason: a global option, so
    // it has to be left of Codex's `resume`/`fork` subcommand. Nothing is
    // emitted for a null model or an agent that takes none.
    ...?launch?.model.argumentsFor(modelId),
    // A global too, and it belongs beside them: the file is context for the
    // whole session rather than something the resume or the prompt carries.
    // Nothing is emitted for an agent that takes none, so a packet aimed at one
    // stays where it was — in the opening prompt.
    ...?launch?.systemPromptFile.argumentsFor(systemPromptFilePath),
    if (sessionId != null && resumeSessionId == null && !forking)
      ...?launch?.sessionIdAssignment.argumentsFor(sessionId),
    if (forking) ...?launch?.fork.argumentsFor(forkSessionId),
    if (!forking && resumeSessionId != null && resumeSessionId.isNotEmpty)
      ...?launch?.interactiveResume.argumentsFor(resumeSessionId),
    // Last, and spread rather than appended: the prompt is a positional for
    // Claude and Codex but two argv entries for Antigravity, and which of those
    // it is belongs to the descriptor rather than to this call site.
    if (trimmedPrompt != null) ...?launch?.prompt.argumentsFor(trimmedPrompt),
  ];
}
