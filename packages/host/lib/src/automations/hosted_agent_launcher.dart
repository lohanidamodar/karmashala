import 'dart:io';

import 'package:agent_cli/discovery.dart';
import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/runner.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_session/launch.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';

import '../domain/session_registry.dart';
import '../pty/pty.dart';
import 'daemon_agents.dart';
import 'session_mcp_access.dart';

/// The environment variable a hook and the MCP bridge read the session from.
const String kSessionIdEnvironmentVariable = 'KARMASHALA_SESSION_ID';

/// Starts an automation's agent as a session this host owns: the row first,
/// then the PTY under the row's host id, so the app attaches to it as to any
/// other hosted session when it opens.
class HostedAgentLauncher implements AutomationSessionLauncher {
  HostedAgentLauncher({
    required this.registry,
    required this.sessions,
    required this.mcp,
    required this.now,
    required this.newId,
    this.agents = const DaemonAgents(),
    Map<String, String>? hostEnvironment,
  }) : _hostEnvironment = hostEnvironment ?? Platform.environment;

  final SessionRegistry registry;
  final SessionDao sessions;
  final SessionMcpAccessPoint mcp;
  final DateTime Function() now;
  final String Function() newId;
  final DaemonAgents agents;
  final Map<String, String> _hostEnvironment;

  @override
  Future<String> launch(
    Automation automation,
    Repository repository,
    AgentInstallation installation,
  ) async {
    final agentId = installation.agentId;
    final refusal = agents.launchRefusal(agentId, automation.prompt);
    if (refusal != null) throw StateError(refusal);

    final id = newId();
    final session = Session(
      id: id,
      repositoryId: repository.id,
      agentInstallationId: installation.id,
      title: automation.name.trim().isEmpty ? 'Session' : automation.name,
      useWorktree: false,
      workingDirectory: repository.path,
      status: SessionStatus.running,
      createdAt: now(),
      externalSessionId: agents.assignsOwnSessionId(agentId) ? id : null,
      surface: SessionSurface.pane,
      view: agents.defaultView(agentId),
      permissionMode: automation.permissionMode?.canonical,
    );
    sessions.insertWithPrimaryRepository(session);

    final access = mcp.accessFor(
      id,
      withConfigFile: agents.mcpNeedsConfigFile(agentId),
    );
    final request = PtySpawnRequest(
      argv: [
        installation.executable.path,
        ...agents.newSessionArguments(
          agentId: agentId,
          sessionId: id,
          permissionMode: automation.permissionMode?.canonical,
          prompt: automation.prompt,
          mcpUrl: access?.url,
          mcpConfigPath: access?.configPath,
        ),
      ],
      workingDirectory: repository.path.path,
      environment: {
        'TERM': 'xterm-256color',
        kSessionIdEnvironmentVariable: id,
      },
      removedEnvironment: agents.withheldEnvironment(agentId, _hostEnvironment),
      columns: 120,
      rows: 40,
    );
    try {
      registry.open(hostSessionIdOf(id), request);
    } on Object {
      // The row must not outlive a launch that never happened.
      sessions.updateStatus(id, SessionStatus.failed);
      rethrow;
    }
    return id;
  }
}
