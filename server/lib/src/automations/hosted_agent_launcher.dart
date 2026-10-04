import 'dart:async';
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
import 'package:karmashala_launch/karmashala_launch.dart'
    show AgentPaneLaunch, survivesWindowsNativeArgv;
import 'package:karmashala_session/launch.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';

import '../acp/acp_arguments.dart';
import '../acp/acp_auth.dart' show AcpStartAuth;
import '../acp/acp_runtimes.dart';
import '../acp/acp_session_runtime.dart';
import '../domain/session_registry.dart';
import '../pty/environment_spawn.dart';
import '../sessions/launch/handoff_routes.dart';
import '../sessions/launch/session_handoffs.dart';
import '../sessions/launch/launch_settings.dart';
import 'daemon_agents.dart';
import 'session_mcp_access.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_session/lineage.dart';

export '../acp/acp_arguments.dart' show acpArgumentsFor;

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
    this.worktreeBranch,
    this.worktreeBase,
    this.worktreeExistingBranch,
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
    this.freshConversationId,
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

  /// With [worktree]: the branch a person named, else the session-named one.
  final String? worktreeBranch;

  /// With [worktree]: what the new branch starts from; null is HEAD.
  final String? worktreeBase;

  /// With [worktree]: an existing branch to check out in the new worktree,
  /// in place of creating [worktreeBranch] from [worktreeBase].
  final String? worktreeExistingBranch;

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

  /// With [fresh]: the id the new conversation is started under where the
  /// agent takes one, over the row's own — which an earlier agent of a
  /// switched row already holds.
  final String? freshConversationId;
}

/// What a start produced.
class HostedStart {
  const HostedStart({
    required this.session,
    this.launch,
    this.external,
    this.credentialNotice,
    this.attachNotice,
  });

  final Session session;

  /// The agent launch the terminal runs, its volatile half stripped: what a
  /// pane stores to name its session. Null for the external surface and for
  /// an ACP session, neither of which has a pane here.
  final AgentPaneLaunch? launch;

  /// The command a client opens a terminal window on (the external surface).
  final ExternalTerminalCommand? external;

  /// Credential variables withheld from the agent, in a person's words.
  final String? credentialNotice;

  /// Said when the terminal attached to the agent's own background session
  /// instead of resuming the conversation, in a person's words.
  final String? attachNotice;
}

/// Opens an agent's terminal: [launch] as a PTY under its session's own id
/// (`karmashala_<sessionId>`), at [columns]×[rows] — on this machine, or on
/// the SSH box its launch names (slice 5d). `ServerTerminals` in `serve`, so
/// the agent is one of the server's terminals like any pane.
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
    this.runnerFor,
    this.vaultNames,
    this.handoffs,
    this.links,
    this.acpRuntimes,
    this.acpAuth,
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

  /// Runs a command to its end in an environment — how an agent is asked
  /// whether its own service holds a conversation before a resume of it.
  /// Null: never asked, and a resume is a resume.
  final CommandRunner Function(String environmentId)? runnerFor;

  /// The names the server's vault sets; a name set there is never withheld.
  final Set<String> Function()? vaultNames;

  /// Where the texts a launch hands its agent are kept, and how they go.
  final SessionHandoffs? handoffs;

  /// Records a session's checkouts beside its primary one.
  final SessionRepositoryDao? links;

  /// Runs an agent whose adapter speaks ACP (`adapter.acp != null`) in place
  /// of a PTY; null refuses such a launch in words.
  final AcpRuntimeFactory? acpRuntimes;

  /// The login remembered for an ACP installation: the spec authenticating
  /// with it, and the variables it reads. Null: the descriptor's own spec.
  final AcpStartAuth Function(
    AgentInstallation installation,
    AcpLaunchSpec spec,
  )?
  acpAuth;

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
    final acp = agents.adapterOf(agentId)?.acp;
    // Over ACP the opening message is the first `session/prompt`, never argv.
    final refusal = agents.launchRefusal(
      agentId,
      acp == null ? launch.prompt ?? '' : '',
    );
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
    final existingBranch = launch.worktreeExistingBranch?.trim();
    if (existingBranch != null && existingBranch.isNotEmpty) {
      if (!launch.worktree) {
        throw ArgumentError(
          'An existing branch is checked out in a new worktree; this launch '
          'makes none.',
        );
      }
      if (launch.worktreeBranch != null || launch.worktreeBase != null) {
        throw ArgumentError(
          'A launch cannot both check out an existing branch and create a '
          'new one.',
        );
      }
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
        branch: existingBranch != null && existingBranch.isNotEmpty
            ? existingBranch
            : launch.worktreeBranch ?? sessionBranchName(id),
        baseRef: launch.worktreeBase,
        existingBranch: existingBranch != null && existingBranch.isNotEmpty,
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
    final ownId = (launch.fresh ? launch.freshConversationId : null) ?? id;

    Session session;
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
      // A fresh conversation in the row is started under the row's own id
      // (or the one given), so the row names it from the start.
      if (launch.fresh && assignsOwnId && resuming.externalSessionId != ownId) {
        sessions.updateExternalSessionId(id, ownId);
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
    final throughPowerShell =
        _windows && kind != EnvironmentKind.wsl && kind != EnvironmentKind.ssh;
    final systemPrompt = acp != null
        ? null
        : _systemPromptHandoff(
            id,
            launch.systemPrompt,
            descriptor,
            kind,
            throughPowerShell: throughPowerShell,
          );
    // A packet the agent takes no system prompt for is its opening message —
    // it ends with the instruction, so nothing is lost.
    final packetAsOpening =
        (launch.systemPrompt?.trim().isNotEmpty ?? false) &&
        systemPrompt == null;
    final openingText = packetAsOpening ? launch.systemPrompt : launch.prompt;
    final openingKind = packetAsOpening
        ? HandoffKind.packet
        : HandoffKind.opening;
    final hasOpening = openingText?.trim().isNotEmpty ?? false;
    final opening = acp != null
        ? _protocolOpening(id, openingText, openingKind)
        : _openingHandoff(
            id,
            openingText,
            openingKind,
            descriptor,
            kind,
            throughPowerShell: throughPowerShell,
            typeable: launch.surface != SessionSurface.external,
          );
    final prompt = opening.argv;
    // An agent pointed at a file would name the session after the pointer;
    // an unnamed one is named from the message instead.
    if (resuming == null &&
        opening.byPointer &&
        openingText != null &&
        isPlaceholderSessionTitle(session.title)) {
      final named = sessionTitleFromMessage(openingText);
      sessions.updateTitle(id, named);
      session = session.copyWith(title: named);
    }
    // A file is read from the session's own temp folder, which an agent that
    // can be granted it gets, so it does not ask to leave its workspace.
    final readableDirectory = opening.folder;
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
    // A conversation the agent keeps in a service of its own is attached to,
    // not resumed: the resume would be refused and the pane would die on it.
    // Never with something to say — an attach carries no prompt.
    final attachId = acp != null || forking || newConversation || hasOpening
        ? null
        : await _backgroundSessionId(
            descriptor,
            installation,
            directory,
            resumeId,
          );
    final durable = attachId != null
        ? descriptor!.launch.backgroundSessions.attachArgumentsFor(attachId)
        : agentPaneArguments(
            descriptor,
            permission,
            modelId: modelId,
            sessionId: assignsOwnId ? ownId : null,
            resumeSessionId: forking ? null : resumeId,
            forkSessionId: launch.forkConversationId,
            prompt: prompt,
            systemPromptFilePath: systemPrompt?.path,
            systemPromptText: systemPrompt?.text,
            extraDirectoryPath: readableDirectory,
            suppressSelfUpdate: suppressUpdate,
          );
    final agentLaunch = AgentPaneLaunch(
      agentId: agentId,
      executable: installation.executable.path,
      arguments: durable,
      // The attached session keeps the tools it was started with.
      mcpArguments: attachId != null
          ? const []
          : agentMcpArguments(
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

    if (acp != null) {
      return _startAcp(
        acp,
        id: id,
        agentId: agentId,
        agentName: descriptor?.displayName ?? agentId,
        installation: installation,
        session: session,
        resuming: resuming,
        directory: directory,
        environment: environment,
        kind: kind,
        resumeId: resumeId,
        risk: descriptor?.launch.permission.riskOf(permission),
        prompt: prompt,
        removed: agentLaunch.removedEnvironment,
        wslDistribution: agentLaunch.wslDistribution,
        sshHostId: agentLaunch.sshHostId,
        credentialNotice: notice,
        settleWorktree: settleWorktree,
      );
    }

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
    try {
      final open = openAgent;
      if (open != null) {
        // On an SSH box too (slice 5d): the server starts it on the box's
        // host, and its exit is the box's fact.
        await open(agentLaunch, launch.columns, launch.rows);
      } else if (kind == EnvironmentKind.ssh) {
        throw StateError(
          '${environment?.name ?? 'That SSH machine'} is reached only through '
          'the server\'s terminals, and none were given to this launcher',
        );
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
    if (opening.pending || (systemPrompt?.pending ?? false)) {
      handoffs?.onPending?.call(id);
    }
    onLaunched?.call(id, agentId, directory.path);
    return HostedStart(
      session: session,
      launch: stored,
      credentialNotice: notice,
      attachNotice: attachId == null
          ? null
          : '${descriptor?.displayName ?? 'The agent'} is running this '
                'conversation in its own background service, so this terminal '
                'attached to it instead of resuming it. Ending the session '
                'here closes the terminal; the conversation carries on there.',
    );
  }

  /// The ACP branch of a start: the runtime in the registry under the row's
  /// host id, started, the agent's session id written to the row, and the
  /// opening message sent as the first prompt. A start that fails leaves the
  /// row as a failed PTY spawn would and rethrows.
  Future<HostedStart> _startAcp(
    AcpLaunchSpec acp, {
    required String id,
    required String agentId,
    required String agentName,
    required AgentInstallation installation,
    required Session session,
    required Session? resuming,
    required EnvironmentPath directory,
    required ExecutionEnvironment? environment,
    required EnvironmentKind kind,
    required String? resumeId,
    required PermissionRisk? risk,
    required String? prompt,
    required Set<String> removed,
    required String? wslDistribution,
    required String? sshHostId,
    required String? credentialNotice,
    required void Function(Object? error)? settleWorktree,
  }) async {
    AcpSessionRuntime? opened;
    try {
      final arguments = acpArgumentsFor(
        installation,
        acp,
        linux: AcpLaunchSpec.runsOnLinux(kind, hostIsLinux: Platform.isLinux),
      );
      final factory = acpRuntimes;
      if (factory == null) {
        throw StateError(
          '$agentName speaks the Agent Client Protocol, and this server was '
          'given no runtime to run it',
        );
      }
      if (kind == EnvironmentKind.ssh) {
        throw StateError(
          '${environment?.name ?? 'That SSH machine'} cannot run $agentName '
          'over ACP from here yet',
        );
      }
      final access = mcp.accessFor(id, withConfigFile: false, kind: kind);
      final auth =
          acpAuth?.call(installation, acp) ??
          (spec: acp, variables: const <String, String>{});
      final runtime = factory(
        AcpSessionStart(
          sessionId: id,
          hostSessionId: hostSessionIdOf(id),
          agentId: agentId,
          agentName: agentName,
          spec: auth.spec,
          executable: installation.executable.path,
          arguments: arguments,
          directory: directory,
          environment: environment,
          variables: {...auth.variables, kSessionIdEnvironmentVariable: id},
          removed: removed,
          mcpUrl: access?.url,
          resumeSessionId: resumeId,
          risk: risk,
        ),
      );
      opened = registry.openAcp(hostSessionIdOf(id), runtime);
      final outcome = await runtime.start();
      if (outcome.agentSessionId != session.externalSessionId) {
        sessions.updateExternalSessionId(id, outcome.agentSessionId);
        onRowWritten?.call(id);
      }
      if (prompt != null && prompt.trim().isNotEmpty) {
        await runtime.send(prompt);
        handoffs?.consume(id);
      }
      settleWorktree?.call(null);
      onLaunched?.call(id, agentId, directory.path);
      return HostedStart(
        session: session.copyWith(externalSessionId: outcome.agentSessionId),
        // No launch: a launch is what a pane attaches a terminal to, and an
        // ACP session has none — the app shows it in the chat view instead.
        launch: null,
        credentialNotice: credentialNotice,
        attachNotice: outcome.notices.isEmpty
            ? null
            : outcome.notices.join(' '),
      );
    } on Object catch (error) {
      settleWorktree?.call(error);
      // Once the registry holds the runtime, its lifecycle records the end
      // as failed too; a resume says the same rather than its old status.
      final ran = opened;
      if (ran != null) unawaited(ran.stop());
      sessions.updateStatus(
        id,
        ran != null
            ? SessionStatus.failed
            : resuming?.status ?? SessionStatus.failed,
      );
      onRowWritten?.call(id);
      rethrow;
    }
  }

  /// The id [installation]'s own service runs [conversationId] under, or
  /// null: it holds none, it has no such service, or it could not be asked —
  /// and "could not tell" is a resume, as before.
  Future<String?> _backgroundSessionId(
    AgentDescriptor? descriptor,
    AgentInstallation installation,
    EnvironmentPath directory,
    String? conversationId,
  ) async {
    final background = descriptor?.launch.backgroundSessions;
    final runner = runnerFor;
    if (background == null ||
        !background.isSupported ||
        runner == null ||
        conversationId == null ||
        conversationId.isEmpty) {
      return null;
    }
    try {
      final listed = await runner(directory.environmentId).run(
        CommandRequest(
          executable: installation.executable.path,
          arguments: background.listArguments,
          workingDirectory: directory,
          timeout: const Duration(seconds: 10),
        ),
      );
      if (listed.exitCode != 0) return null;
      return background.attachIdIn(listed.stdout, conversationId);
    } on Object {
      return null;
    }
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

  /// [text], [sessionId]'s opening message, as the launch hands it over.
  ///
  /// A Windows-native command line crosses PowerShell 5.1, `cmd.exe` (npm's
  /// `.cmd` shim) and the program's argv parser: a `"` splits it, a newline
  /// cuts it to its first line. What argv cannot carry is typed into the
  /// composer once the agent is ready where that is lossless for it, else
  /// written to the session's temp folder and pointed at in one plain line.
  /// Without a store, or when a file or its path cannot be had, [text] goes
  /// on argv as it is.
  _Opening _openingHandoff(
    String sessionId,
    String? text,
    HandoffKind handoffKind,
    AgentDescriptor? descriptor,
    EnvironmentKind kind, {
    required bool throughPowerShell,
    required bool typeable,
  }) {
    final trimmed = text?.trim();
    final store = handoffs;
    if (trimmed == null || trimmed.isEmpty || store == null) {
      return _Opening(text);
    }
    final route = openingRoute(
      trimmed,
      descriptor: descriptor,
      throughPowerShell: throughPowerShell,
      typeable: typeable,
    );
    if (route == HandoffRoute.typed) {
      store.record(sessionId, handoffKind, trimmed, route);
      return const _Opening(null, pending: true);
    }
    if (route == HandoffRoute.file) {
      final written = store.writeFile(sessionId, handoffKind, trimmed);
      final path = written == null ? null : agentConfigPathFor(written, kind);
      final pointer = path == null
          ? null
          : promptFilePointer(
              path,
              isPacket: handoffKind == HandoffKind.packet,
            );
      if (pointer != null &&
          (!throughPowerShell || survivesWindowsNativeArgv(pointer))) {
        store.record(sessionId, handoffKind, trimmed, route);
        return _Opening(
          pointer,
          folder: agentConfigPathFor(store.folderOf(sessionId).path, kind),
          pending: true,
        );
      }
      store.consume(sessionId, kind: handoffKind);
    }
    store.record(sessionId, handoffKind, trimmed, HandoffRoute.argv);
    return _Opening(text);
  }

  /// [text] as an ACP agent's first `session/prompt`, recorded until sent.
  _Opening _protocolOpening(
    String sessionId,
    String? text,
    HandoffKind handoffKind,
  ) {
    final trimmed = text?.trim();
    if (trimmed != null && trimmed.isNotEmpty) {
      handoffs?.record(sessionId, handoffKind, trimmed, HandoffRoute.protocol);
    }
    return _Opening(text);
  }

  /// [text], a packet, as [descriptor]'s agent takes a system prompt — inline
  /// where the command line carries it, else a file spelled as the agent in
  /// [kind] names it — or null: it then travels as the opening message.
  _SystemPrompt? _systemPromptHandoff(
    String sessionId,
    String? text,
    AgentDescriptor? descriptor,
    EnvironmentKind kind, {
    required bool throughPowerShell,
  }) {
    final content = text?.trim();
    final store = handoffs;
    if (content == null || content.isEmpty || store == null) return null;
    final route = systemPromptRoute(
      content,
      support:
          descriptor?.launch.systemPromptFile ??
          const AgentSystemPromptFileSupport.unchecked(),
      throughPowerShell: throughPowerShell,
    );
    if (route == HandoffRoute.argv) {
      store.record(
        sessionId,
        HandoffKind.systemPrompt,
        content,
        HandoffRoute.argv,
      );
      return _SystemPrompt(text: content);
    }
    if (route != HandoffRoute.file) return null;
    final written = store.writeFile(
      sessionId,
      HandoffKind.systemPrompt,
      content,
    );
    final path = written == null ? null : agentConfigPathFor(written, kind);
    if (path == null) {
      store.consume(sessionId, kind: HandoffKind.systemPrompt);
      return null;
    }
    store.record(
      sessionId,
      HandoffKind.systemPrompt,
      content,
      HandoffRoute.file,
    );
    return _SystemPrompt(path: path, pending: true);
  }
}

/// What a launch's opening message became: what rides on argv, the folder an
/// agent pointed at a file is granted, and whether a row waits to be used.
class _Opening {
  const _Opening(this.argv, {this.folder, this.pending = false});

  final String? argv;
  final String? folder;
  final bool pending;

  /// Whether argv carries a pointer at a file rather than the message.
  bool get byPointer => pending && argv != null;
}

/// How a packet rides as a system prompt: inline [text] or a file at [path].
class _SystemPrompt {
  const _SystemPrompt({this.text, this.path, this.pending = false});

  final String? text;
  final String? path;
  final bool pending;
}
