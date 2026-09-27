import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/launch.dart'
    show
        InheritedCredentialDecision,
        decideInheritedCredentials,
        inheritedCredentialNotice;
import 'package:agent_cli/process.dart';
import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/runner.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show ExternalTerminalCommand;
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_git/worktrees.dart';
import 'package:karmashala_launch/karmashala_launch.dart' show AgentPaneLaunch;
import 'package:karmashala_session/launch.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';

import '../domain/session_registry.dart';
import '../pty/environment_spawn.dart';
import '../sessions/launch/handoff_packet_files.dart';
import '../sessions/launch/launch_settings.dart';
import 'daemon_agents.dart';
import 'session_mcp_access.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_session/lineage.dart';

/// The environment variable a hook and the MCP bridge read the session from.
const String kSessionIdEnvironmentVariable = 'KARMASHALA_SESSION_ID';

/// One agent session this host is asked to start: a new conversation, or —
/// with [resuming] — that row's own conversation continued.
class HostedLaunch {
  const HostedLaunch({
    required this.repository,
    required this.installation,
    required this.title,
    this.titleTyped = false,
    this.permissionMode,
    this.prompt,
    this.worktree = false,
    this.resuming,
    this.parentSessionId,
    this.parentLink,
    this.id,
    this.modelId,
    this.resumeConversationId,
    this.forkConversationId,
    this.existingWorktree,
    this.workingDirectory,
    this.recordDirectory = true,
    this.additionalRepositoryIds = const [],
    this.systemPrompt,
    this.view,
    this.surface = SessionSurface.pane,
    this.columns = 120,
    this.rows = 40,
    this.followSettings = false,
    this.fresh = false,
  });

  final Repository repository;
  final AgentInstallation installation;

  /// Empty becomes "Session", as the desktop's own dialog names one.
  final String title;

  /// Whether a person typed [title] (a phone's start), so the row records it
  /// as theirs and no agent title replaces it — `newSessionTitle`'s rule.
  /// An automation's name is not.
  final bool titleTyped;

  /// The mode chosen, canonically; null is the row's own (when resuming),
  /// else the agent's declared default.
  final String? permissionMode;

  /// The opening message, when there is one — for a resume too, typed on the
  /// command line after the conversation's resume arguments.
  final String? prompt;

  /// Start in a worktree of its own, on a new branch.
  final bool worktree;

  /// The row being continued: its id, its conversation, its directory, its
  /// mode and model are kept (unless named here), and it is marked running.
  final Session? resuming;

  /// The session that asked for this one (an agent's `open_new_session`, a
  /// handoff, a fork), and why — a spawn unless said otherwise.
  final String? parentSessionId;
  final SessionLink? parentLink;

  /// The id a new row takes, when the caller already named files after it.
  final String? id;

  /// The model chosen; null is the row's own, else the agent's default.
  final String? modelId;

  /// The conversation to continue, over [resuming]'s own — a row repaired
  /// back onto the conversation it started on. A new row may name one too.
  final String? resumeConversationId;

  /// The conversation a fork is seeded from (the CLI mints its own id).
  final String? forkConversationId;

  /// A worktree that already exists, joined rather than created — what a
  /// handoff on the same branch needs.
  final EnvironmentPath? existingWorktree;

  /// Where to run, without claiming it is a worktree.
  final EnvironmentPath? workingDirectory;

  /// Whether [workingDirectory] is written to the row: not when the launch
  /// fell back off a directory that has gone (the record is kept).
  final bool recordDirectory;
  final List<String> additionalRepositoryIds;

  /// A handoff packet, handed to an agent that takes a system-prompt file; the
  /// opening message otherwise.
  final String? systemPrompt;
  final SessionView? view;
  final SessionSurface surface;
  final int columns;
  final int rows;

  /// Whether a mode and a model nobody chose follow a person's Settings (a
  /// start a person or an agent asked for), rather than the agent's own
  /// declared defaults — what an automation's unattended gate judged, and a
  /// phone's start, which always names its mode.
  final bool followSettings;

  /// With [resuming]: keep the row and start a **new** conversation in it —
  /// a row whose agent never named one, or one a person restarts afresh.
  final bool fresh;
}

/// What a start produced.
class HostedStart {
  const HostedStart({
    required this.session,
    this.launch,
    this.clientRuns = false,
    this.external,
    this.credentialNotice,
  });

  final Session session;

  /// The agent launch the terminal runs, its volatile half stripped: what a
  /// pane stores to name its session. Null only for the external surface.
  final AgentPaneLaunch? launch;

  /// The client must run [launch] itself (an SSH checkout, until slice 5d).
  final bool clientRuns;

  /// The command a client opens a terminal window on (the external surface).
  final ExternalTerminalCommand? external;

  /// Credential variables withheld from the agent, in a person's words.
  final String? credentialNotice;
}

/// Opens an agent's terminal: [launch] as a PTY under its session's own id
/// (`karmashala_<sessionId>`), at [columns]×[rows]. `ServerTerminals` in
/// `serve`, so the agent is one of the server's terminals like any pane.
typedef AgentTerminalOpener =
    Future<void> Function(AgentPaneLaunch launch, int columns, int rows);

/// Starts an agent as a session this host owns: the row first, then the PTY
/// under the row's host id, so a client attaches to it as to any other hosted
/// session. Every start comes through [start] — a person's in the app, an
/// agent's `open_new_session`, a handoff or a fork, an automation's run, a
/// phone's start or resume — so each is launched exactly the same way.
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
    this.onRowWritten,
    this.environmentOf,
    this.openAgent,
    this.settings,
    this.hasUsableLogin,
    this.vaultNames,
    this.handoffFiles,
    this.links,
    Map<String, String>? hostEnvironment,
    bool? windows,
  }) : _hostEnvironment = hostEnvironment ?? Platform.environment,
       _windows = windows ?? Platform.isWindows;

  final SessionRegistry registry;
  final SessionDao sessions;
  final SessionMcpAccessPoint mcp;
  final DateTime Function() now;
  final String Function() newId;
  final DaemonAgents agents;

  /// How a session that asked for a worktree of its own gets one — the
  /// staged creation, with this host's setup panes. Null: none are made here.
  final WorktreeService? worktrees;

  /// Told of each agent started, with where: the daemon watches an unattended
  /// start for a question nobody is there to answer.
  final void Function(String sessionId, String agentId, String directory)?
  onLaunched;

  /// Told of each row written — created, or its status moved — so every
  /// client hears of it on the data channel.
  final void Function(String sessionId)? onRowWritten;

  /// The environment a checkout names, so an agent in a WSL distribution is
  /// started through `wsl.exe` (slice 5a). Null, or an unknown id: this
  /// machine's own.
  final ExecutionEnvironment? Function(String environmentId)? environmentOf;

  /// Opens the agent's terminal; null opens it straight in [registry].
  final AgentTerminalOpener? openAgent;

  /// A person's Settings, read on every launch; null is every default.
  final LaunchSettings Function()? settings;

  /// Whether an interactive login exists for an installation — asked only
  /// when an inherited credential would outrank it. Null: never withheld.
  final Future<bool> Function(AgentInstallation installation)? hasUsableLogin;

  /// The names the server's vault sets; a name set there is never withheld.
  final Set<String> Function()? vaultNames;

  /// Where a handoff packet is written for an agent that takes a file.
  final HandoffPacketFiles? handoffFiles;

  /// Records a session's checkouts beside its primary one.
  final SessionRepositoryDao? links;

  final Map<String, String> _hostEnvironment;
  final bool _windows;

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
  Future<Session> start(HostedLaunch launch) async =>
      (await startDetailed(launch)).session;

  /// [start], answering what was started and how a client shows it.
  Future<HostedStart> startDetailed(HostedLaunch launch) async {
    final installation = launch.installation;
    final agentId = installation.agentId;
    final descriptor = agents.descriptorOf(agentId);
    final refusal = agents.launchRefusal(agentId, launch.prompt ?? '');
    if (refusal != null) throw StateError(refusal);
    final resuming = launch.resuming;
    final resumeId = launch.fresh
        ? null
        : launch.resumeConversationId ?? resuming?.externalSessionId;
    if (resuming != null &&
        !launch.fresh &&
        launch.forkConversationId == null &&
        (resumeId == null || resumeId.isEmpty)) {
      throw StateError('this session has no conversation to resume');
    }
    if (launch.worktree && resuming != null) {
      throw ArgumentError('a resume continues where it was; it makes no tree');
    }
    if (launch.worktree && launch.existingWorktree != null) {
      throw ArgumentError(
        'A launch cannot both create a worktree and join an existing one.',
      );
    }

    final id = resuming?.id ?? launch.id ?? newId();
    var directory =
        launch.existingWorktree ??
        launch.workingDirectory ??
        resuming?.workingDirectory ??
        resuming?.worktree ??
        launch.repository.path;
    EnvironmentPath? worktree = launch.existingWorktree ?? resuming?.worktree;
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
    final record = launch.recordDirectory;
    final forking = launch.forkConversationId != null;
    // A new conversation gets *our* id where the agent takes one; a fork is a
    // create and mints its own.
    final assignsOwnId =
        (resumeId == null || resumeId.isEmpty) &&
        !forking &&
        agents.assignsOwnSessionId(agentId);

    final Session session;
    if (resuming != null) {
      session = resuming.copyWith(
        status: SessionStatus.running,
        permissionMode: launch.permissionMode,
        modelId: launch.modelId,
        workingDirectory: record ? directory : null,
      );
      sessions.updateStatus(id, SessionStatus.running);
      if (launch.permissionMode != null) {
        sessions.updatePermissionMode(id, launch.permissionMode);
      }
      if (launch.modelId != null) sessions.updateModel(id, launch.modelId);
      if (record && launch.workingDirectory != null) {
        sessions.updateWorkingDirectory(id, directory);
      }
      if (resumeId != null && resumeId != resuming.externalSessionId) {
        sessions.updateExternalSessionId(id, resumeId);
      }
      // A fresh conversation in the row is started under the row's own id,
      // so the row names it from the start.
      if (launch.fresh && assignsOwnId && resuming.externalSessionId != id) {
        sessions.updateExternalSessionId(id, id);
      }
    } else {
      final named = newSessionTitle(launch.title, typed: launch.titleTyped);
      session = Session(
        id: id,
        repositoryId: launch.repository.id,
        agentInstallationId: installation.id,
        title: named.title,
        titleByUser: named.byUser,
        useWorktree: worktree != null,
        worktree: worktree,
        workingDirectory: record ? directory : null,
        status: SessionStatus.running,
        createdAt: now(),
        externalSessionId: resumeId != null && resumeId.isNotEmpty
            ? resumeId
            : (assignsOwnId ? id : null),
        surface: launch.surface,
        view: launch.view ?? agents.defaultView(agentId),
        permissionMode: launch.permissionMode,
        modelId: launch.modelId,
        parentSessionId: launch.parentSessionId,
        parentLink: launch.parentSessionId == null
            ? null
            : (launch.parentLink ?? SessionLink.spawn),
      );
      sessions.insertWithPrimaryRepository(session);
    }
    for (final extra in launch.additionalRepositoryIds) {
      links?.link(id, extra);
    }
    onRowWritten?.call(id);

    final environment = environmentOf?.call(directory.environmentId);
    final kind = environment?.kind ?? EnvironmentKind.localPosix;
    final policy = settings?.call() ?? LaunchSettings.none;
    final access = descriptor?.launch.mcp.isSupported ?? false
        ? mcp.accessFor(
            id,
            withConfigFile: agents.mcpNeedsConfigFile(agentId),
            kind: kind,
          )
        : null;
    // Off by default on Windows: a self-updating agent under an unsigned
    // parent is a behavioural-antivirus dropper signal.
    final suppressUpdate =
        descriptor != null &&
        descriptor.launch.selfUpdate.canSuppress &&
        !policy.agentsMayUpdateThemselves(windows: _windows);
    final inherits =
        kind == EnvironmentKind.localPosix ||
        kind == EnvironmentKind.windowsNative;
    final credentials = inherits
        ? await _credentialDecision(installation)
        : InheritedCredentialDecision.none;
    final systemPromptPath = _systemPromptFile(
      id,
      launch.systemPrompt,
      descriptor,
      kind,
    );
    // A packet that could not travel as a file travels as the opening message
    // — it ends with the instruction, so nothing is lost.
    final prompt = launch.systemPrompt != null && systemPromptPath == null
        ? launch.systemPrompt
        : launch.prompt;
    final newConversation = resumeId == null || resumeId.isEmpty;
    final permission = launch.followSettings
        ? agents.permissionOf(
            agentId,
            resolveSessionPermission(
              sessionMode: session.permissionMode,
              newSessionDefault: policy.newSessionModes[agentId],
              existingSessionDefault: policy.existingSessionModes[agentId],
              purpose: newConversation
                  ? SessionPurpose.newSession
                  : SessionPurpose.existingSession,
            ).stored,
          )
        : agents.permissionOf(agentId, session.permissionMode);
    final modelId = launch.followSettings
        ? resolveSessionModel(
            sessionModelId: session.modelId,
            defaultModelId: policy.defaultModels[agentId],
          ).modelId
        : session.modelId;
    final durable = agentPaneArguments(
      descriptor,
      permission,
      modelId: modelId,
      sessionId: assignsOwnId ? id : null,
      resumeSessionId: forking ? null : resumeId,
      forkSessionId: launch.forkConversationId,
      prompt: prompt,
      systemPromptFilePath: systemPromptPath,
      suppressSelfUpdate: suppressUpdate,
    );
    final agentLaunch = AgentPaneLaunch(
      agentId: agentId,
      executable: installation.executable.path,
      arguments: durable,
      mcpArguments: agentMcpArguments(
        descriptor,
        url: access?.url,
        configPath: access?.configPath,
      ),
      environment: suppressUpdate
          ? descriptor.launch.selfUpdate.disableEnvironment
          : const {},
      removedEnvironment: {
        ...credentials.removed,
        if (inherits) ...agents.withheldEnvironment(agentId, _hostEnvironment),
      },
      workingDirectory: directory.path,
      wslDistribution: kind == EnvironmentKind.wsl
          ? environment?.wslDistribution
          : null,
      sshHostId: kind == EnvironmentKind.ssh ? environment?.sshHostId : null,
      sessionId: id,
      title: session.title,
    );
    final stored = AgentPaneLaunch(
      agentId: agentLaunch.agentId,
      executable: agentLaunch.executable,
      arguments: agentLaunch.arguments,
      workingDirectory: agentLaunch.workingDirectory,
      wslDistribution: agentLaunch.wslDistribution,
      sshHostId: agentLaunch.sshHostId,
      sessionId: id,
      title: session.title,
    );
    final notice = credentials.changedEnvironment
        ? inheritedCredentialNotice(credentials)
        : null;

    if (launch.surface == SessionSurface.external) {
      // Launched into a window nobody here can see: `running` would be a
      // claim nothing observes. The agent's own hooks move the row from here.
      sessions.updateStatus(id, SessionStatus.unknown);
      onRowWritten?.call(id);
      settleWorktree?.call(null);
      return HostedStart(
        session: session.copyWith(status: SessionStatus.unknown),
        external: ExternalTerminalCommand(
          executable: installation.executable.path,
          arguments: agentLaunch.commandArguments,
          workingDirectory: directory.path,
          wslDistribution: agentLaunch.wslDistribution,
        ),
        credentialNotice: notice,
      );
    }
    if (kind == EnvironmentKind.ssh) {
      // An SSH box's panes are the client's until slice 5d: it runs this.
      settleWorktree?.call(null);
      onLaunched?.call(id, agentId, directory.path);
      return HostedStart(
        session: session,
        launch: agentLaunch,
        clientRuns: true,
        credentialNotice: notice,
      );
    }
    try {
      final open = openAgent;
      if (open != null) {
        await open(agentLaunch, launch.columns, launch.rows);
      } else {
        registry.open(
          hostSessionIdOf(id),
          spawnRequestIn(
            environment,
            argv: [
              installation.executable.path,
              ...agentLaunch.commandArguments,
            ],
            directory: directory.path,
            variables: {
              kSessionIdEnvironmentVariable: id,
              ...agentLaunch.environment,
            },
            removed: agentLaunch.removedEnvironment,
            columns: launch.columns,
            rows: launch.rows,
          ),
        );
      }
    } on Object catch (error) {
      settleWorktree?.call(error);
      // The row must not outlive a launch that never happened; a resumed one
      // goes back to how it had ended.
      sessions.updateStatus(id, resuming?.status ?? SessionStatus.failed);
      onRowWritten?.call(id);
      rethrow;
    }
    settleWorktree?.call(null);
    onLaunched?.call(id, agentId, directory.path);
    return HostedStart(
      session: session,
      launch: stored,
      credentialNotice: notice,
    );
  }

  /// What to withhold of the Anthropic credentials this server's own
  /// environment would hand an agent that signs in through Anthropic's login.
  Future<InheritedCredentialDecision> _credentialDecision(
    AgentInstallation installation,
  ) async {
    final accounts = agents.adapterOf(installation.agentId)?.accounts;
    final login = hasUsableLogin;
    if (accounts is! AnthropicOAuthAccounts || login == null) {
      return InheritedCredentialDecision.none;
    }
    final wouldInherit = accounts.inheritedCredentialVariables.any(
      (name) => (_hostEnvironment[name] ?? '').trim().isNotEmpty,
    );
    if (!wouldInherit) return InheritedCredentialDecision.none;
    bool usable;
    try {
      usable = await login(installation);
    } on Object {
      usable = false;
    }
    return decideInheritedCredentials(
      hostEnvironment: _hostEnvironment,
      settingsEnvironment: {
        for (final name in vaultNames?.call() ?? const <String>{}) name: '1',
      },
      hasUsableLogin: usable,
    );
  }

  /// The system-prompt file [text] is handed over as, spelled as the agent in
  /// [kind] names it, or null — every null falls back to the opening message.
  String? _systemPromptFile(
    String sessionId,
    String? text,
    AgentDescriptor? descriptor,
    EnvironmentKind kind,
  ) {
    final content = text?.trim();
    final files = handoffFiles;
    if (content == null || content.isEmpty || files == null) return null;
    final support =
        descriptor?.launch.systemPromptFile ??
        const AgentSystemPromptFileSupport.unchecked();
    if (!support.isSupported) return null;
    final written = files.write(
      sessionId: sessionId,
      packet: content,
      liveSessionIds: {for (final row in sessions.getClaimingLive()) row.id},
    );
    return written == null ? null : agentConfigPathFor(written, kind);
  }
}
