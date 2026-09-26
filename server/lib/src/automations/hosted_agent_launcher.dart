import 'dart:io';

import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/runner.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_git/worktrees.dart';
import 'package:karmashala_session/launch.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';

import '../domain/session_registry.dart';
import '../pty/pty.dart';
import 'daemon_agents.dart';
import 'session_mcp_access.dart';

/// The environment variable a hook and the MCP bridge read the session from.
const String kSessionIdEnvironmentVariable = 'KARMASHALA_SESSION_ID';

/// One agent session this host is asked to start: a new conversation, or —
/// with [resuming] — that row's own conversation continued.
class HostedLaunch {
  const HostedLaunch({
    required this.repository,
    required this.installation,
    required this.title,
    this.permissionMode,
    this.prompt,
    this.worktree = false,
    this.resuming,
  });

  final Repository repository;
  final AgentInstallation installation;

  /// Empty becomes "Session", as the desktop's own dialog names one.
  final String title;

  /// The mode chosen, canonically; null is the agent's declared default.
  final String? permissionMode;

  /// The opening message, when there is one.
  final String? prompt;

  /// Start in a worktree of its own, on a new branch.
  final bool worktree;

  /// The row being resumed: its id, its conversation, its directory, its mode
  /// and model are kept, and it is marked running again.
  final Session? resuming;
}

/// Starts an agent as a session this host owns: the row first, then the PTY
/// under the row's host id, so the app attaches to it as to any other hosted
/// session when it opens. An automation's run and a phone's start or resume
/// all come through [start], so each is launched exactly the same way.
class HostedAgentLauncher implements AutomationSessionLauncher {
  HostedAgentLauncher({
    required this.registry,
    required this.sessions,
    required this.mcp,
    required this.now,
    required this.newId,
    this.agents = const DaemonAgents(),
    this.worktrees,
    this.onLaunched,
    Map<String, String>? hostEnvironment,
  }) : _hostEnvironment = hostEnvironment ?? Platform.environment;

  final SessionRegistry registry;
  final SessionDao sessions;
  final SessionMcpAccessPoint mcp;
  final DateTime Function() now;
  final String Function() newId;
  final DaemonAgents agents;

  /// How a session that asked for a worktree of its own gets one — the app's
  /// staged creation, with this host's setup panes. Null: none are made here.
  final WorktreeService? worktrees;

  /// Told of each agent started, with where: the daemon watches an unattended
  /// start for a question nobody is there to answer.
  final void Function(String sessionId, String agentId, String directory)?
  onLaunched;

  final Map<String, String> _hostEnvironment;

  @override
  Future<String> launch(
    Automation automation,
    Repository repository,
    AgentInstallation installation,
  ) async => (await start(
    HostedLaunch(
      repository: repository,
      installation: installation,
      title: automation.name,
      permissionMode: automation.permissionMode?.canonical,
      prompt: automation.prompt,
    ),
  )).id;

  /// Writes the row and opens its PTY. Throws [StateError] in words for a
  /// launch refused before anything was written; a PTY that would not start
  /// leaves the row `failed` (a new one) and rethrows.
  Future<Session> start(HostedLaunch launch) async {
    final installation = launch.installation;
    final agentId = installation.agentId;
    final refusal = agents.launchRefusal(agentId, launch.prompt ?? '');
    if (refusal != null) throw StateError(refusal);
    final resuming = launch.resuming;
    final resumeId = resuming?.externalSessionId;
    if (resuming != null && (resumeId == null || resumeId.isEmpty)) {
      throw StateError('this session has no conversation to resume');
    }
    if (launch.worktree && resuming != null) {
      throw ArgumentError('a resume continues where it was; it makes no tree');
    }

    final id = resuming?.id ?? newId();
    var directory =
        resuming?.workingDirectory ??
        resuming?.worktree ??
        launch.repository.path;
    EnvironmentPath? worktree = resuming?.worktree;
    void Function(Object? error)? settleWorktree;
    if (launch.worktree) {
      final service = worktrees;
      if (service == null) {
        throw StateError('this machine makes no worktrees for a session');
      }
      final created = await service.create(
        repo: launch.repository.path,
        worktreeName: sessionWorktreeName(id),
        branch: sessionBranchName(id),
        launchesAgent: true,
      );
      directory = created.worktree.path;
      worktree = created.worktree.path;
      settleWorktree = (error) => error == null
          ? created.tracker.agentStarted()
          : created.tracker.agentFailed(error);
    }

    final Session session;
    if (resuming != null) {
      session = resuming.copyWith(status: SessionStatus.running);
      sessions.updateStatus(id, SessionStatus.running);
    } else {
      final title = launch.title.trim();
      session = Session(
        id: id,
        repositoryId: launch.repository.id,
        agentInstallationId: installation.id,
        title: title.isEmpty ? 'Session' : title,
        useWorktree: worktree != null,
        worktree: worktree,
        workingDirectory: directory,
        status: SessionStatus.running,
        createdAt: now(),
        externalSessionId: agents.assignsOwnSessionId(agentId) ? id : null,
        surface: SessionSurface.pane,
        view: agents.defaultView(agentId),
        permissionMode: launch.permissionMode,
      );
      sessions.insertWithPrimaryRepository(session);
    }

    final access = mcp.accessFor(
      id,
      withConfigFile: agents.mcpNeedsConfigFile(agentId),
    );
    final request = PtySpawnRequest(
      argv: [
        installation.executable.path,
        ...agents.sessionArguments(
          agentId: agentId,
          sessionId: id,
          permissionMode: session.permissionMode,
          modelId: session.modelId,
          prompt: resuming == null ? launch.prompt : null,
          resumeConversationId: resumeId,
          mcpUrl: access?.url,
          mcpConfigPath: access?.configPath,
        ),
      ],
      workingDirectory: directory.path,
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
    } on Object catch (error) {
      settleWorktree?.call(error);
      // The row must not outlive a launch that never happened; a resumed one
      // goes back to how it had ended.
      sessions.updateStatus(id, resuming?.status ?? SessionStatus.failed);
      rethrow;
    }
    settleWorktree?.call(null);
    onLaunched?.call(id, agentId, directory.path);
    return session;
  }
}
