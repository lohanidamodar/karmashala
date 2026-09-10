/// The command line one agent launch is handed, per agent. **Order is the
/// whole of it**, and it is the order the shipped agents want, not a tidy one.
library;

import 'package:agent_cli/descriptors.dart';
import 'session_mcp_arguments.dart';

/// The arguments for one agent launch, in the order the agents want: a fork
/// **replaces** resume, and [AgentPromptSupport] decides the prompt's shape.
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
    // First, because Codex's `-c` is a global and its resume a *subcommand*:
    // everything global has to be on the left of it, and none of it variadic.
    ...agentMcpArguments(descriptor, url: mcpUrl, configPath: mcpConfigPath),
    ...?launch?.permission.argumentsFor(permissionMode),
    // Beside the permission flags and for the same reason: a global option, so
    // it has to be left of Codex's `resume`/`fork` subcommand.
    ...?launch?.model.argumentsFor(modelId),
    // A global too: the file is context for the whole session, and nothing is
    // emitted for an agent that takes none.
    ...?launch?.systemPromptFile.argumentsFor(systemPromptFilePath),
    if (sessionId != null && resumeSessionId == null && !forking)
      ...?launch?.sessionIdAssignment.argumentsFor(sessionId),
    if (forking) ...?launch?.fork.argumentsFor(forkSessionId),
    if (!forking && resumeSessionId != null && resumeSessionId.isNotEmpty)
      ...?launch?.interactiveResume.argumentsFor(resumeSessionId),
    // Last, and spread rather than appended: the prompt is a positional for
    // Claude and Codex but two argv entries for Antigravity.
    if (trimmedPrompt != null) ...?launch?.prompt.argumentsFor(trimmedPrompt),
  ];
}
