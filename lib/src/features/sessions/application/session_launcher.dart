import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/util/clock_provider.dart';
import '../../../core/util/id_generator_provider.dart';
import '../../agents/application/agent_installations_controller.dart';
import '../../agents/application/agent_providers.dart';
import '../../agents/domain/agent_descriptor.dart';
import '../../agents/domain/agent_installation.dart';
import '../../environments/application/environment_providers.dart';
import '../../environments/domain/environment_path.dart';
import '../../git/application/git_providers.dart';
import '../../settings/application/settings_controller.dart';
import '../../settings/domain/permission_mode.dart';
import '../../terminal/application/system_terminal_providers.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import '../../terminal/domain/agent_pane_launch.dart';
import '../data/session_repository_dao.dart';
import '../domain/session.dart';
import '../domain/session_attribution.dart';
import '../domain/session_depth.dart';
import '../domain/session_launch.dart';
import '../domain/session_status.dart';
import 'session_providers.dart';
import 'session_ui_providers.dart';

/// What a launch produced.
class SessionLaunchResult {
  const SessionLaunchResult({required this.session, this.paneId, this.tabId});

  final Session session;
  final String? paneId;
  final String? tabId;
}

/// Raised when the recursion cap or the cycle guard refuses a launch.
///
/// Its own type so the MCP surface can fail the caller's *turn* with the
/// explanation rather than reporting a generic error.
class SessionDepthRefused implements Exception {
  const SessionDepthRefused(this.depth);
  final SessionDepth depth;

  @override
  String toString() => depth.refusal;
}

/// **The** way a session comes into existence.
///
/// Loop 33's audit (§6) found nine entry points reaching four mechanisms, only
/// two of which wrote a `sessions` row; permission mode resolved in eight places
/// with three different answers; and `useWorktree` reachable from one path of
/// nine. This class is where those decisions were moved to. dray's rule is the
/// target: a session created by an agent "is not a second kind of session."
///
/// Three things follow from that and are worth stating, because each was a
/// divergence:
///
/// * **Every in-app session runs in a PTY**, whatever agent it is. The three
///   agents with a protocol adapter do not get a different runtime; they get a
///   second *view* over the same one (see [SessionView]). An adapter is an
///   enhancement layer and is never load-bearing for whether the session is
///   alive.
/// * **Every started session gets a row**, including one launched into an
///   external terminal. Those used to change real-world state with no record and
///   no UI feedback, surfacing later as an unrelated `ImportedSession`.
/// * **Permission mode is resolved here and nowhere else**, from the caller's
///   [SessionPurpose].
class SessionLauncher {
  SessionLauncher(this._ref);

  final Ref _ref;

  /// The single permission-mode resolution in the app.
  ///
  /// The engine's own `PermissionMode.ask` default was dead code — every caller
  /// overrode it — so the safe default was not a backstop. It is one here:
  /// nothing else reads `permissionsFor`.
  PermissionMode permissionFor(String agentId, SessionPurpose purpose) {
    final permissions = _ref
        .read(settingsControllerProvider)
        .permissionsFor(agentId);
    return switch (purpose) {
      SessionPurpose.newSession => permissions.newSessions,
      SessionPurpose.existingSession => permissions.existingSessions,
    };
  }

  /// The single default-installation resolution.
  ///
  /// Four variants of this existed, and only some of them consulted the user's
  /// configured default at all.
  AgentInstallation? defaultInstallationIn(String environmentId) {
    final installs = _ref
        .read(agentInstallationDaoProvider)
        .getByEnvironment(environmentId);
    if (installs.isEmpty) return null;
    final settings = _ref.read(settingsControllerProvider);
    return resolveDefaultInstallation(
          installs,
          defaultInstallationId: settings.defaultAgentInstallationId,
          defaultAgentId: settings.defaultAgent,
        ) ??
        installs.first;
  }

  /// Where a depth walk reads from. Exposed so the MCP surface can check the cap
  /// before doing any work it would have to undo.
  SessionDepth depthForChildOf(String? parentSessionId) =>
      SessionDepth.forChildOf(
        parentSessionId,
        _ref.read(sessionDaoProvider).parentOf,
      );

  /// Creates the session row and starts it on the requested surface.
  Future<SessionLaunchResult> launch(SessionLaunchRequest request) async {
    final depth = depthForChildOf(request.parentSessionId);
    if (!depth.isAllowed) throw SessionDepthRefused(depth);

    final descriptor = _ref
        .read(agentRegistryProvider)
        .byId(request.installation.agentId);
    final permissionMode =
        request.permissionOverride ??
        permissionFor(request.installation.agentId, request.purpose);

    final id = _ref.read(idGeneratorProvider).newId();

    var workingDirectory = request.repository.path;
    EnvironmentPath? worktree;
    if (request.useWorktree) {
      final created = await _ref
          .read(worktreeServiceProvider)
          .createForSession(
            repo: request.repository.path,
            worktreeName: id.substring(0, 8),
            branch: 'session/${id.substring(0, 8)}',
          );
      workingDirectory = created.path;
      worktree = created.path;
    }

    // A resumed session already has a CLI id. A new one gets *ours* when the
    // agent will accept it — our ids are RFC-4122 v4, which is what
    // `--session-id` wants — so the transcript that backs the chat view is
    // locatable at launch instead of guessed at afterwards. Agents that cannot
    // be told (Codex) keep a null id until something discovers it.
    final assignsOwnId =
        request.resumeExternalSessionId == null &&
        (descriptor?.launch.sessionIdAssignment.isSupported ?? false);
    final externalSessionId =
        request.resumeExternalSessionId ?? (assignsOwnId ? id : null);

    // A session an agent asked for names its parent in the prompt, because the
    // prompt is the only channel the spawned agent has. Built from the parent's
    // own row, and stripped again by rebuilding the same string — never by
    // pattern-matching the text. See [SessionAttribution].
    final attribution = _attributionFor(request.parentSessionId);
    final firstMessage = attribution == null || request.firstMessage == null
        ? request.firstMessage
        : attribution.render(request.firstMessage!);

    final session = Session(
      id: id,
      repositoryId: request.repository.id,
      agentInstallationId: request.installation.id,
      title: request.title.trim().isEmpty ? 'Session' : request.title.trim(),
      useWorktree: request.useWorktree,
      worktree: worktree,
      status: SessionStatus.running,
      createdAt: _ref.read(clockProvider).nowUtc(),
      externalSessionId: externalSessionId,
      parentSessionId: request.parentSessionId,
      surface: request.surface,
      view: request.view ?? defaultViewFor(descriptor),
    );
    final dao = _ref.read(sessionDaoProvider);
    dao.insert(session);
    final repositoryDao = _ref.read(sessionRepositoryDaoProvider)
      ..link(id, request.repository.id, role: SessionRepositoryRole.primary);
    for (final extra in request.additionalRepositories) {
      repositoryDao.link(id, extra.id);
    }

    try {
      final result = switch (request.surface) {
        SessionSurface.pane => _startInPane(
          session,
          request,
          descriptor,
          permissionMode,
          workingDirectory,
          assignsOwnId,
          firstMessage,
        ),
        SessionSurface.external => await _startInExternalTerminal(
          session,
          request,
          descriptor,
          permissionMode,
          workingDirectory,
          assignsOwnId,
          firstMessage,
        ),
      };
      _bump();
      return result;
    } catch (_) {
      // The row must not outlive a launch that never happened — that is exactly
      // the "session created as a side effect nothing observes" the audit found,
      // wearing the opposite hat.
      dao.updateStatus(id, SessionStatus.failed);
      _bump();
      rethrow;
    }
  }

  SessionLaunchResult _startInPane(
    Session session,
    SessionLaunchRequest request,
    AgentDescriptor? descriptor,
    PermissionMode permissionMode,
    EnvironmentPath workingDirectory,
    bool assignsOwnId,
    String? firstMessage,
  ) {
    final environment = _ref
        .read(executionEnvironmentDaoProvider)
        .getById(workingDirectory.environmentId);
    if (environment == null) {
      throw StateError('The repository\'s environment is unavailable.');
    }
    final launch = AgentPaneLaunch(
      agentId: request.installation.agentId,
      executable: request.installation.executable.path,
      arguments: agentPaneArguments(
        descriptor,
        permissionMode,
        sessionId: assignsOwnId ? session.id : null,
        resumeSessionId: request.resumeExternalSessionId,
        prompt: firstMessage,
      ),
      workingDirectory: workingDirectory.path,
      wslDistribution: environment.wslDistribution,
      sessionId: session.id,
      title: session.title,
    );
    final opened = _ref
        .read(terminalSessionsControllerProvider.notifier)
        .openAgentTab(launch);
    _ref.read(sessionDaoProvider).updatePaneId(session.id, opened.paneId);
    _ref.read(terminalVisibleProvider.notifier).set(true);
    return SessionLaunchResult(
      session: session.copyWith(paneId: opened.paneId),
      paneId: opened.paneId,
      tabId: opened.tabId,
    );
  }

  Future<SessionLaunchResult> _startInExternalTerminal(
    Session session,
    SessionLaunchRequest request,
    AgentDescriptor? descriptor,
    PermissionMode permissionMode,
    EnvironmentPath workingDirectory,
    bool assignsOwnId,
    String? firstMessage,
  ) async {
    final environment = _ref
        .read(executionEnvironmentDaoProvider)
        .getById(workingDirectory.environmentId);
    if (environment == null) {
      throw StateError('The repository\'s environment is unavailable.');
    }
    final terminal =
        request.externalTerminal ??
        await _ref.read(defaultSystemTerminalProvider.future);
    if (terminal == null) {
      throw StateError('No external terminal is configured.');
    }
    final agentCommand = [
      request.installation.executable.path,
      ...agentPaneArguments(
        descriptor,
        permissionMode,
        sessionId: assignsOwnId ? session.id : null,
        resumeSessionId: request.resumeExternalSessionId,
        prompt: firstMessage,
      ),
    ];
    final distro = environment.wslDistribution;
    final command = distro == null
        ? agentCommand
        : [
            'wsl.exe',
            '-d',
            distro,
            '--cd',
            workingDirectory.path,
            '--',
            ...agentCommand,
          ];
    await _ref
        .read(systemTerminalServiceProvider)
        .launch(
          terminal,
          command: command,
          workingDirectory: distro == null ? workingDirectory.path : null,
        );
    return SessionLaunchResult(session: session);
  }

  /// The attribution for a session spawned by [parentSessionId], or `null` for
  /// one the user started. Reads the parent's real title so the prefix and the
  /// strip are built from the same data.
  SessionAttribution? _attributionFor(String? parentSessionId) {
    if (parentSessionId == null) return null;
    final parent = _ref.read(sessionDaoProvider).getById(parentSessionId);
    if (parent == null) return null;
    return SessionAttribution(sessionId: parent.id, title: parent.title);
  }

  /// Types [text] into a PTY-hosted session, exactly as if the user had.
  ///
  /// This is what "the composer and the terminal are two views of one session"
  /// means at the input end: there is no second write path into the agent, so a
  /// message sent from chat and one typed into the pane are indistinguishable to
  /// the CLI, and neither can get out of step with the other.
  ///
  /// Returns false when the session has no live pane — a restored record, an
  /// external terminal, or a session that has ended — so the caller can say so
  /// rather than silently dropping the message.
  bool sendTo(String sessionId, String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return false;
    final session = _ref.read(sessionDaoProvider).getById(sessionId);
    final paneId = session?.paneId;
    if (paneId == null) return false;
    final controller = _ref.read(terminalSessionsControllerProvider.notifier);
    final instance = controller.instanceFor(paneId);
    if (instance == null || !instance.liveness.value.isLive) return false;
    // A carriage return, not a newline: a PTY line discipline reads CR as
    // "submit", and a bare LF leaves the text sitting in the agent's composer.
    instance.terminal
      ..textInput(trimmed)
      ..textInput('\r');
    return true;
  }

  void _bump() => _ref.read(sessionsRevisionProvider.notifier).bump();
}

/// The interactive command-line arguments for one agent launch.
///
/// Shared by the pane and external-terminal surfaces so the two cannot drift:
/// "open this in Windows Terminal instead" must produce the same agent, in the
/// same mode, on the same conversation.
///
/// Order matters and is the order the shipped agents want: global flags, then
/// the session-id flag, then the resume convention (which for Codex is a
/// *subcommand* and must follow the globals), then the prompt as a positional
/// argument.
List<String> agentPaneArguments(
  AgentDescriptor? descriptor,
  PermissionMode permissionMode, {
  String? sessionId,
  String? resumeSessionId,
  String? prompt,
}) {
  final launch = descriptor?.launch;
  final trimmedPrompt = prompt?.trim();
  return [
    ...?launch?.permissionArgumentsFor(permissionMode),
    if (sessionId != null && resumeSessionId == null)
      ...?launch?.sessionIdAssignment.argumentsFor(sessionId),
    if (resumeSessionId != null && resumeSessionId.isNotEmpty)
      ...?launch?.interactiveResume.argumentsFor(resumeSessionId),
    if (trimmedPrompt != null &&
        trimmedPrompt.isNotEmpty &&
        (launch?.acceptsPromptArgument ?? false))
      trimmedPrompt,
  ];
}

final sessionLauncherProvider = Provider<SessionLauncher>(
  (ref) => SessionLauncher(ref),
);
