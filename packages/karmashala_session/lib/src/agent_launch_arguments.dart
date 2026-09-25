/// The command line one agent launch is handed, per agent. **Order is the
/// whole of it**, and it is the order the shipped agents want, not a tidy one.
library;

import 'package:agent_cli/descriptors.dart';

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
  bool suppressSelfUpdate = false,
}) {
  final launch = descriptor?.launch;
  final trimmedPrompt = prompt?.trim();
  final forking = forkSessionId != null && forkSessionId.isNotEmpty;
  return [
    // First: Codex's `-c` is a global and its resume a subcommand.
    ...agentMcpArguments(descriptor, url: mcpUrl, configPath: mcpConfigPath),
    if (suppressSelfUpdate) ...?launch?.selfUpdate.disableArguments,
    ...?launch?.permission.argumentsFor(permissionMode),
    ...?launch?.model.argumentsFor(modelId),
    ...?launch?.systemPromptFile.argumentsFor(systemPromptFilePath),
    if (sessionId != null && resumeSessionId == null && !forking)
      ...?launch?.sessionIdAssignment.argumentsFor(sessionId),
    if (forking) ...?launch?.fork.argumentsFor(forkSessionId),
    if (!forking && resumeSessionId != null && resumeSessionId.isNotEmpty)
      ...?launch?.interactiveResume.argumentsFor(resumeSessionId),
    // Last, and spread: a positional for Claude and Codex, two for Antigravity.
    if (trimmedPrompt != null) ...?launch?.prompt.argumentsFor(trimmedPrompt),
  ];
}

/// The flags that point one agent at Karmashala's MCP endpoint — the only
/// volatile half of a command line, so they are rebuilt each launch.
List<String> agentMcpArguments(
  AgentDescriptor? descriptor, {
  String? url,
  String? configPath,
}) {
  final support = descriptor?.launch.mcp;
  if (support == null) return const [];
  if (support.needsConfigFile) {
    return configPath == null || configPath.isEmpty
        ? const []
        : support.argumentsFor(url: url, configPath: configPath);
  }
  return url == null || url.isEmpty
      ? const []
      : support.argumentsFor(url: url, configPath: configPath);
}
