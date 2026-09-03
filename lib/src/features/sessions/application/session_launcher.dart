import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../../../core/logging/app_logger.dart';
import '../../../core/util/clock_provider.dart';
import '../../../core/util/id_generator_provider.dart';
import '../../agents/application/agent_installations_controller.dart';
import '../../agents/application/agent_providers.dart';
import '../../agents/domain/agent_descriptor.dart';
import '../../agents/domain/agent_installation.dart';
import '../../agents/domain/agent_status.dart';
import '../../cli_detection/application/cli_detection_providers.dart';
import '../../cli_detection/domain/conversation_presence.dart';
import '../../environments/application/environment_providers.dart';
import '../../environments/domain/environment_path.dart';
import '../../environments/domain/execution_environment.dart';
import '../../git/application/git_providers.dart';
import '../../mcp/session_mcp.dart';
import '../../repositories/application/repository_providers.dart';
import '../../settings/application/settings_controller.dart';
import '../../agents/domain/agent_permission_support.dart';
import '../../terminal/application/system_terminal_providers.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import '../../terminal/data/pty_launch.dart';
import '../../terminal/data/system_terminal_service.dart';
import '../../terminal/domain/agent_pane_launch.dart';
import '../../terminal/domain/launch_context.dart';
import '../../terminal/domain/pane_liveness.dart';
import '../data/session_repository_dao.dart';
import '../domain/session.dart';
import '../domain/session_attribution.dart';
import '../domain/session_depth.dart';
import '../domain/session_launch.dart';
import '../domain/session_lineage.dart';
import '../domain/session_naming.dart';
import '../domain/session_model.dart';
import '../domain/session_permission.dart';
import '../domain/session_resume.dart';
import '../domain/session_status.dart';
import 'decision_recorder.dart';
import 'session_mcp_arguments.dart';
import 'session_providers.dart';
import 'session_status_providers.dart';
import 'session_ui_providers.dart';
import 'session_working_directory.dart';

/// What a launch produced.
class SessionLaunchResult {
  const SessionLaunchResult({
    required this.session,
    this.paneId,
    this.tabId,
    this.workingDirectoryNotice,
  });

  final Session session;
  final String? paneId;
  final String? tabId;

  /// Plain words for the user when the session could not start where it was
  /// recorded as running, and started somewhere else instead.
  ///
  /// Null in the ordinary case. Non-null is not a failure — the session is up —
  /// but it is the one thing the user must be told, because the agent is now
  /// looking at a different tree from the one its transcript describes.
  ///
  /// It used to justify itself with "a resume in the wrong directory is how an
  /// agent CLI quietly opens a new conversation". That is the cmux claim, and it
  /// does not survive contact with the three CLIs we launch — see
  /// [AgentResumeLocality]. An agent for which it *would* be true never reaches
  /// this notice at all: [SessionLauncher.refuseIfConversationIsElsewhere]
  /// refuses the launch instead.
  final String? workingDirectoryNotice;
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

/// Raised when a launch was asked to carry an opening message that the agent's
/// command line cannot take.
///
/// Its own type for the same reason as [SessionDepthRefused]: the MCP surface
/// and fan-out both need to fail the caller with the explanation, rather than
/// starting an agent that never hears the instruction and reporting success.
class SessionLaunchRefused implements Exception {
  const SessionLaunchRefused(this.reason);
  final String reason;

  @override
  String toString() => reason;
}

/// Raised when a resume would start a **second** agent on a conversation whose
/// first one is still running, **and that agent will not share it**.
///
/// Loop 38 separated session lifetime from view lifetime: closing a tab detaches
/// the view and leaves the process running. So "resume this session" stopped
/// meaning "nothing is running it" — and launching anyway hands the agent CLI a
/// transcript it already holds open. Codex refuses that outright:
///
/// ```
/// thread/resume failed: thread <id> already has an active writer (code -32600)
/// ```
///
/// which reaches the user as a raw JSON-RPC failure during TUI bootstrap. That
/// string never reaches the user from here: [toString] is the plain-words
/// version, and it is what the UI shows.
///
/// **Only thrown for an agent that forbids it.** Loop 46 made that conditional:
/// this used to fire for every agent, which refused the case Claude Code
/// actually supports — a second terminal listening to the same conversation.
/// See [AgentLaunchSpec.allowsConcurrentResume] and [resumeActionFor].
///
/// In-app surfaces that *can* reopen the running view do so instead and never
/// get here, so this is thrown where reopening is not what was asked for —
/// handing the session to an external terminal — and by [SessionLauncher.launch]
/// itself, as the backstop no future caller can forget.
class SessionAlreadyRunning implements Exception {
  const SessionAlreadyRunning({
    required this.agentName,
    this.sessionId,
    this.title,
  });

  /// The session already running it — the one to reveal. Null when the holder is
  /// a process we do not own, which we only ever learn from the agent's own
  /// refusal.
  final String? sessionId;

  /// That session's title, when it is one of ours.
  final String? title;

  /// The agent's display name, so the refusal says *who* is refusing. Naming it
  /// is what makes "start a new session instead" read as a property of this CLI
  /// rather than a limitation of Karmashala.
  final String agentName;

  @override
  String toString() {
    final where = title == null
        ? 'That conversation is already open in another process.'
        : '"$title" is already running in Karmashala.';
    return '$where ${resumeBlockedMessage(agentName)}';
  }
}

/// Raised when a resume names a conversation the agent's own store has never
/// held.
///
/// The other side of `sessionIdAssignment`. Passing Claude Code our id as
/// `--session-id` is what lets a row know its conversation without parsing
/// anything, but it also means the row records that id **before** the CLI has
/// written a single byte — so a launch that failed, or a session nothing was
/// ever said in, leaves a row claiming a conversation that does not exist.
/// Nothing distinguished such a row from a real one, and resuming it ran
///
/// ```
/// No conversation found with session ID: 4b13c55e-…
/// [process exited with code 1]
/// ```
///
/// on the user's screen while the app said nothing and went on creating
/// sessions around it.
///
/// **Only thrown on certain knowledge.** The store must have been read to the
/// end without the conversation in it; a store we could not locate or reach
/// answers `unknown` and the resume proceeds exactly as it did before (see
/// `conversationPresenceProvider`).
class SessionConversationMissing implements Exception {
  const SessionConversationMissing({
    required this.agentName,
    required this.conversationId,
    this.sessionId,
    this.title,
  });

  /// The CLI id that names nothing. Included in [toString] because a user whose
  /// store is configured somewhere unusual needs to be able to go and look.
  final String conversationId;

  /// Our row for it, so a caller can reveal or tidy it.
  final String? sessionId;

  /// That row's title, for the message.
  final String? title;

  /// The agent's display name, so the sentence says who has no record.
  final String agentName;

  @override
  String toString() {
    final what = title == null ? 'This session' : '"$title"';
    return '$what cannot be resumed: '
        '${resumeMissingConversationMessage(agentName)} '
        '(conversation id $conversationId)';
  }
}

/// Why a model change could not reach the session running now.
///
/// Four reasons rather than a bool, because the chip has to say which one and
/// they are not interchangeable: "the agent is mid-turn" is a *wait a moment*,
/// "this CLI takes its model from the command line" is a *never*, and telling a
/// user the second when the first is true would send them looking for a setting
/// that does not exist.
enum ModelDeferral {
  /// Nothing of ours is running this session.
  notRunning,

  /// The agent is mid-turn, holding a prompt, or in a state no source can
  /// vouch for. A line typed into any of those lands in the user's own input.
  busy,

  /// The agent has no in-session command that takes a model name. Codex's
  /// `/model` opens a picker, which is not the same thing.
  noCommand,

  /// Nothing to switch *to*: the session was handed back to a default that
  /// names no model, so the agent's own default applies from the next launch.
  noModel,
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

  /// Every launch says what it decided.
  ///
  /// This path had no logging at all, and four of the bugs found in it were
  /// silent by construction: a permission mode written over the row it was
  /// reusing, `external_session_id` never stored for one agent, a resume that
  /// quietly started a new conversation, and a dormant pane not being reused so
  /// one session got two terminals. None of them threw; each produced a
  /// plausible-looking session that was wrong in a way only the command line
  /// showed. One line per launch, naming what was chosen, is what makes the
  /// next one of those answerable from a log instead of a repro.
  static final _log = AppLogger.named('sessions.launch');

  /// The single permission resolution in the app.
  ///
  /// Two steps, and both have to happen here: [resolveSessionPermission] says
  /// *which stored preference wins* (the session's own, or the per-agent
  /// default), and the agent's own [AgentPermissionSupport] says what that
  /// string means — filling in its default, translating a pre-v35 name, and
  /// turning the result into flags. Neither half can answer alone: the
  /// precedence rule is the same for every agent and the vocabulary is not.
  ///
  /// A caller holding a session row passes its [sessionMode]; one that has no
  /// session yet (a shell command for a project, a brand-new launch) leaves it
  /// null and gets the default for [purpose].
  PermissionSelection permissionFor(
    String agentId,
    SessionPurpose purpose, {
    String? sessionMode,
  }) {
    final stored = resolveSessionPermission(
      sessionMode: sessionMode,
      defaults: _ref.read(settingsControllerProvider).permissionsFor(agentId),
      purpose: purpose,
    ).stored;
    final support = _ref.read(agentRegistryProvider).byId(agentId)?.launch.permission;
    return support?.resolveStored(stored) ?? PermissionSelection.empty;
  }

  /// The same, already turned into the flags a launch passes.
  ResolvedPermission resolvedPermissionFor(
    String agentId,
    SessionPurpose purpose, {
    String? sessionMode,
  }) {
    final support = _ref.read(agentRegistryProvider).byId(agentId)?.launch.permission;
    if (support == null || !support.isKnown) return ResolvedPermission.none;
    return ResolvedPermission.of(
      support,
      permissionFor(agentId, purpose, sessionMode: sessionMode),
    );
  }

  /// The mode [sessionId] will run under on its next launch or resume, and the
  /// agent it will be handed to.
  ///
  /// The read behind the composer control, so what the chip shows and what the
  /// launcher passes come from one place by construction rather than by two
  /// call sites agreeing. `inherited` is [SessionPermission.followsDefault]:
  /// the session made no choice and is tracking the setting live, which the
  /// control has to be able to say out loud rather than showing the resolved
  /// value as if this session had picked it.
  ({
    PermissionSelection selection,
    AgentDescriptor? descriptor,
    bool inherited,
    bool unrecognised,
  })?
  effectivePermissionFor(String sessionId) {
    final session = _ref.read(sessionDaoProvider).getById(sessionId);
    if (session == null) return null;
    final installation = _ref
        .read(agentInstallationDaoProvider)
        .getById(session.agentInstallationId);
    if (installation == null) return null;
    final resolved = resolveSessionPermission(
      sessionMode: session.permissionMode,
      defaults: _ref
          .read(settingsControllerProvider)
          .permissionsFor(installation.agentId),
      purpose: SessionPurpose.existingSession,
    );
    final descriptor = _ref
        .read(agentRegistryProvider)
        .byId(installation.agentId);
    final support = descriptor?.launch.permission;
    // A row written by a newer build can name a value this one has never heard
    // of. `resolveStored` substitutes the agent's default for it, which is the
    // only thing it can do — there are no arguments to pass for a mode we do
    // not know — but doing that *silently* would be the claim this whole area
    // exists to remove, so the fact travels with the answer.
    final stored = PermissionSelection.parse(resolved.stored);
    return (
      selection:
          support?.resolveStored(resolved.stored) ?? PermissionSelection.empty,
      descriptor: descriptor,
      inherited: resolved.followsDefault,
      unrecognised: (support?.unknownAxes(stored) ?? const []).isNotEmpty,
    );
  }

  /// Records the mode [sessionId] should run under from its next launch on, or
  /// with a null [selection] that it should follow the per-agent default again.
  ///
  /// Deliberately **does not touch the running process**. Every agent here
  /// takes its permission policy from its command line at startup; none of them
  /// has a documented way to be told a new one mid-session, and typing a slash
  /// command at whatever has focus would be a guess about another program's
  /// UI. So this writes the row, and the control says the change applies on the
  /// next launch rather than implying the live agent has been re-governed.
  ///
  /// The one thing that *can* move a running session onto a new policy is a new
  /// command line, and [restartSession] is that: the agent is replaced, not
  /// re-governed, so nothing above stops being true. It stays a separate call
  /// rather than a flag here, because the two acts are not comparable — writing
  /// a row is cheap and reversible, and ending an agent that may be mid-turn is
  /// neither, so it must never happen as a side effect of recording a choice.
  void setPermissionMode(String sessionId, PermissionSelection? selection) {
    _ref
        .read(sessionDaoProvider)
        .updatePermissionMode(sessionId, selection?.canonical);
    // One row's own policy. Only the chip that draws it is watching.
    _publish(SessionChange.reconfigured(sessionId));
  }

  /// The default model for [agentId], for a session that has not chosen one.
  ///
  /// The Settings preference, read **live** rather than captured, so a session
  /// that never chose moves when the setting moves — exactly as
  /// [permissionFor] reads the per-agent permission default.
  ///
  /// **Null is still an answer, and still the shipped one.** "Let the agent
  /// choose" is a setting a user can hold on purpose: no model flag is passed
  /// and the CLI starts on whatever it is configured to use. Widening it to
  /// some invented model name would be the failure `AgentPermissionValue`
  /// documents in the other direction — a claim that a session is running on a
  /// particular model when nothing was ever passed to make that true.
  ///
  /// It is a method rather than an inline lookup so the preference has one
  /// place to be read, reached by both the chip and the launch path — the
  /// property that kept permission-mode resolution from splitting into eight.
  String? defaultModelFor(String agentId) =>
      _ref.read(settingsControllerProvider).defaultModelFor(agentId);

  /// The model [sessionId] will run on at its next launch or resume, and the
  /// agent it will be handed to.
  ///
  /// [effectivePermissionFor]'s twin, and it exists for the same reason: what
  /// the chip shows and what the launcher passes come from one call rather than
  /// two call sites that agree today. `inherited` is
  /// [SessionModel.followsDefault] — the session made no choice and tracks the
  /// per-agent default live.
  ///
  /// A null `modelId` is an answer, not a gap: no model is named anywhere, so
  /// no model flag is passed and the agent starts on whatever it is configured
  /// to use.
  ///
  /// `defaultModelId` is what the Settings preference says *today*, carried out
  /// of the same call rather than looked up again by the caller: the menu has
  /// to name what "follow the default" resolves to, and a second read of the
  /// setting is a second answer waiting to disagree with this one.
  ({
    String? modelId,
    String? defaultModelId,
    AgentDescriptor? descriptor,
    bool inherited,
  })?
  effectiveModelFor(String sessionId) {
    final session = _ref.read(sessionDaoProvider).getById(sessionId);
    if (session == null) return null;
    final installation = _ref
        .read(agentInstallationDaoProvider)
        .getById(session.agentInstallationId);
    if (installation == null) return null;
    final defaultModelId = defaultModelFor(installation.agentId);
    final resolved = resolveSessionModel(
      sessionModelId: session.modelId,
      defaultModelId: defaultModelId,
    );
    return (
      modelId: resolved.modelId,
      defaultModelId: defaultModelId,
      descriptor: _ref.read(agentRegistryProvider).byId(installation.agentId),
      inherited: resolved.followsDefault,
    );
  }

  /// Why a model change would **not** reach the session running now, or null
  /// when it would.
  ///
  /// Asked twice from two places and answered once: the menu asks it as it
  /// opens, to badge each row `now` or `next launch`, and [setModel] asks it
  /// after the row is written to say what actually happened. Two copies of this
  /// rule would be a control whose promise and whose outcome could disagree,
  /// which is the one failure this design cannot have.
  ///
  /// It deliberately says nothing about *which* model: whether a session can be
  /// moved in place is a property of the agent and the moment, not of the
  /// destination. The one target-dependent answer — there is no model to switch
  /// to — belongs to [setModel], which knows what was picked.
  ModelDeferral? liveModelSwitchBlockerFor(String sessionId) {
    final support = effectiveModelFor(sessionId)?.descriptor?.launch.model;
    if (support == null || !support.switchesLive) {
      return ModelDeferral.noCommand;
    }
    if (livePaneFor(sessionId) == null) return ModelDeferral.notRunning;
    return _ref.read(sessionActivityLookupProvider)(sessionId) ==
            AgentActivityStatus.idle
        ? null
        : ModelDeferral.busy;
  }

  /// Records the model [sessionId] should run on — or with a null [modelId]
  /// that it follows the per-agent default again — and, **where and only where
  /// that is safe**, moves the session running now as well.
  ///
  /// The one place in the app that decides between the two, and the order of
  /// the gates is the design:
  ///
  /// 1. **The row is written first, always.** Whichever way the rest goes, the
  ///    next launch runs on what the user picked; a live switch that did not
  ///    persist would be undone by the next restart, and a user who moved to
  ///    Opus and came back to Sonnet would have no way to know why.
  /// 2. **The target is resolved after the write**, so "follow the default"
  ///    switches the running session to whatever the default names rather than
  ///    leaving it where it was. A default that names nothing has nothing to
  ///    switch *to*, which is [ModelDeferral.noModel] and not a failure.
  /// 3. **The agent must have an in-session command**, read off its descriptor
  ///    and never off its name — Codex's `/model` is a picker and takes no
  ///    argument, so Codex is [ModelDeferral.noCommand]. See
  ///    `built_in_agents.dart`.
  /// 4. **The session must be running**, and
  /// 5. **it must be idle.** Typing into a pane that is mid-turn or holding a
  ///    prompt is not a harmless no-op: the line lands in whatever is reading
  ///    input, which is the user's own conversation. `unknown` counts as busy
  ///    for the reason [AgentWaitKind] gives about keystrokes — a state we
  ///    cannot vouch for is not one to type into.
  ///
  /// Returns which of the two happened so the caller can *say so*. A control
  /// that silently means two different things depending on which pane you are
  /// in is the whole risk of doing this at all.
  ({bool switchedNow, String? command, ModelDeferral? deferral}) setModel(
    String sessionId,
    String? modelId,
  ) {
    _ref.read(sessionDaoProvider).updateModel(sessionId, modelId);
    // One row's own policy, exactly as a permission change publishes it.
    _publish(SessionChange.reconfigured(sessionId));

    final effective = effectiveModelFor(sessionId);
    final target = effective?.modelId;
    if (target == null) {
      return (
        switchedNow: false,
        command: null,
        deferral: ModelDeferral.noModel,
      );
    }
    final blocker = liveModelSwitchBlockerFor(sessionId);
    if (blocker != null) {
      return (switchedNow: false, command: null, deferral: blocker);
    }
    final command = effective?.descriptor?.launch.model.commandFor(target);
    // Through [sendTo] rather than a second write path: a slash command is a
    // line typed at the agent's prompt, and it must be submitted exactly the
    // way a message is — `\r`, because a PTY line discipline reads a bare
    // newline as text and leaves the command sitting in the composer.
    if (command == null || !sendTo(sessionId, command)) {
      return (
        switchedNow: false,
        command: null,
        deferral: ModelDeferral.notRunning,
      );
    }
    _log.info('Switched $sessionId to $target in place with "$command"');
    return (switchedNow: true, command: command, deferral: null);
  }

  /// Ends the agent [sessionId] is running now and starts a new one on the same
  /// conversation — the only way a mode written by [setPermissionMode] can
  /// reach a session that is already up.
  ///
  /// This does not contradict the reasoning above; it is the other half of it.
  /// Nothing here talks to the live process about its policy. The process is
  /// *replaced* by one whose command line carries the new flags, and the
  /// conversation is carried across by the agent's own resume convention, so
  /// the user keeps the transcript and loses only the turn that was in flight.
  ///
  /// **Every refusal happens before anything is killed.** A row that has gone,
  /// a conversation the CLI has never named, a repository or an installation no
  /// longer in the workspace — each is checked while the agent is still
  /// running, so a restart that cannot happen costs the user nothing. Ordered
  /// the other way, the same conditions would end working sessions and then
  /// explain why they could not be restarted.
  ///
  /// The conversation id is the load-bearing one. Without it the relaunch has
  /// nothing to hand the resume convention, so the agent would come up on a
  /// *new* conversation wearing this session's row, title and history — the
  /// silent loss [SessionConversationMissing] guards against from the other
  /// direction. A Codex session spends its first moments in exactly that state,
  /// because Codex will not accept an id from us and one is only discovered
  /// afterwards, so this is an ordinary condition and not a corrupt row.
  ///
  /// The pane does not survive, and cannot: a pane will not take a second
  /// process while the first is still in it (see
  /// [TerminalSessionsController.startAgentInPane], which refuses a live pane)
  /// and there is no way to stop that process without disposing the terminal
  /// showing it. What the user is continuing is the agent's transcript rather
  /// than this run's scrollback, and `--resume` is what brings that back —
  /// including into the chat view, which is built from the agent's own store
  /// and never from the buffer.
  ///
  /// Note what is deliberately *not* passed to [launch]. No permission
  /// override: the mode is on the row by the time this is called and [launch]
  /// reads it from there, whereas an override would also be written back, which
  /// is precisely what freezes a session that is deliberately following the
  /// Settings default. No working directory either: the row already carries it,
  /// and restating it here would be a second answer able to disagree with the
  /// one every other resume gets.
  Future<SessionLaunchResult> restartSession(String sessionId) async {
    final session = _ref.read(sessionDaoProvider).getById(sessionId);
    if (session == null) {
      throw StateError('This session no longer exists.');
    }
    final installation = _ref
        .read(agentInstallationDaoProvider)
        .getById(session.agentInstallationId);
    if (installation == null) {
      throw StateError(
        'The agent for this session is not installed. '
        'Run "Discover agents" in Settings.',
      );
    }
    final repository = _ref
        .read(repositoryDaoProvider)
        .getById(session.repositoryId);
    if (repository == null) {
      throw StateError('The session\'s repository is no longer available.');
    }
    final externalId = session.externalSessionId;
    if (externalId == null || externalId.isEmpty) {
      throw StateError(
        '${agentDisplayName(installation.agentId)} has not named a '
        'conversation for this session yet, so restarting it would open a new '
        'conversation instead of continuing this one.',
      );
    }

    // Only now, once nothing above can refuse. Ending is not undoable: the
    // agent is asked to exit and killed if it will not, and whatever it was in
    // the middle of goes with it.
    //
    // A session with no live pane is not an error here — it is a session that
    // already stopped, and starting it again is exactly what was asked for.
    final paneId = livePaneFor(sessionId);
    if (paneId != null) {
      _ref.read(terminalSessionsControllerProvider.notifier).endSession(paneId);
    }
    // After the kill, not before it, so the line records an agent that is
    // actually gone rather than one we were about to end — and gone is the
    // fact a user asking "where did my agent go" needs, whether or not the
    // launch below succeeds. [launch] logs the process that replaced it.
    _log.info(
      'Restarting $sessionId to apply its permission mode: '
      'agent=${installation.agentId} ended=${paneId ?? 'nothing'} '
      'conversation=$externalId',
    );

    return launch(
      SessionLaunchRequest(
        repository: repository,
        installation: installation,
        title: session.title,
        purpose: SessionPurpose.existingSession,
        resumeExternalSessionId: externalId,
        // So [_reusableRowForResume] continues *this* row instead of minting a
        // second one beside it: it compares the request's surface against the
        // candidate's, and a mismatch is one of the ways a single conversation
        // ended up with two rows before Loop 66.
        surface: session.surface,
      ),
    );
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

  // --- is it already running? ------------------------------------------------

  /// The pane [sessionId] is running in **right now**, or `null`.
  ///
  /// Three things have to be true, and each of them has been wrong on its own:
  /// the row must exist, it must name a pane, and that pane's instance must say
  /// it is live. A detached pane is live (Loop 38); a pane restored from disk is
  /// not, whatever its buffer shows.
  String? livePaneFor(String? sessionId) {
    if (sessionId == null) return null;
    final paneId = _ref.read(sessionDaoProvider).getById(sessionId)?.paneId;
    if (paneId == null) return null;
    final instance = _ref
        .read(terminalSessionsControllerProvider.notifier)
        .instanceFor(paneId);
    return instance != null && instance.liveness.value.isLive ? paneId : null;
  }

  /// The pane [sessionId] was **restored** into and has never run, or `null`.
  ///
  /// Deliberately a second question rather than a loosening of [livePaneFor],
  /// because the two are asked for opposite reasons and both answers are
  /// load-bearing. A dormant pane is replayed history with nothing behind it,
  /// so it must never be reattached and presented as a running session — which
  /// is what [livePaneFor] gates, for the double-writer refusal, the archive
  /// guard and the permission chip. But it *is* a real pane holding this
  /// session's own scrollback, so resuming into it is what leaves the user one
  /// terminal for one session instead of a dead pane and a live one side by
  /// side.
  ///
  /// A pane whose process ran and exited is not dormant: it belongs to this run
  /// of the app, its buffer has moved on since anything was restored into it,
  /// and a resume gets a pane of its own. [PaneLiveness.restored] is the only
  /// state that says "rebuilt from disk, never started".
  String? dormantPaneFor(String? sessionId) {
    if (sessionId == null) return null;
    final paneId = _ref.read(sessionDaoProvider).getById(sessionId)?.paneId;
    if (paneId == null) return null;
    final instance = _ref
        .read(terminalSessionsControllerProvider.notifier)
        .instanceFor(paneId);
    return instance?.liveness.value == PaneLiveness.restored ? paneId : null;
  }

  /// The session we are already running the CLI conversation
  /// [externalSessionId] in, or `null`.
  ///
  /// The external id is the join: an imported CLI entry and one of our rows are
  /// two records of the same conversation, and resuming the imported one while
  /// our own process holds it is exactly the double-writer case.
  ///
  /// **Every** row with that id is examined, not the first one the database
  /// hands back. `external_session_id` has no `UNIQUE` constraint and a resume
  /// used to mint a second row for a conversation that already had one, so a
  /// single-row read answered with whichever the engine felt like — and a dead
  /// duplicate answers "nothing is running this" while a pane is still writing
  /// to it. That is the answer this method exists to never give: it gates the
  /// refusal that keeps a second writer off a Codex thread.
  ///
  /// Newest-first (see `SessionDao.getAllByExternalSessionId`), so when an agent
  /// permits two live processes on one conversation the one just started is the
  /// one named.
  Session? runningSessionWithExternalId(String? externalSessionId) {
    if (externalSessionId == null || externalSessionId.isEmpty) return null;
    for (final candidate
        in _ref
            .read(sessionDaoProvider)
            .getAllByExternalSessionId(externalSessionId)) {
      if (livePaneFor(candidate.id) != null) return candidate;
    }
    return null;
  }

  /// Brings the pane [sessionId] is already running in back into view and
  /// selects it. Returns false when nothing of ours is running it.
  ///
  /// This is what "resume" should do for a session that never stopped: a
  /// detached pane comes back as a tab, one already in a tab is focused, and
  /// nothing is created. The same three lines used to live inline in the MCP
  /// surface and nowhere else, which is why every other path relaunched.
  bool reveal(String sessionId) {
    final paneId = livePaneFor(sessionId);
    if (paneId == null) return false;
    _ref.read(terminalSessionsControllerProvider.notifier)
      ..reattachSession(paneId)
      ..focusPane(paneId);
    _ref.read(terminalVisibleProvider.notifier).set(true);
    _ref.read(selectedSessionIdProvider.notifier).select(sessionId);
    // Where this session is on screen moved; nothing was created or renamed.
    _publish(SessionChange.moved(sessionId));
    return true;
  }

  // --- may a second process have it? -----------------------------------------

  /// Whether [agentId] permits a second process on a conversation another one is
  /// already holding.
  ///
  /// The single read of [AgentLaunchSpec.allowsConcurrentResume] in the app, so
  /// "Claude can, Codex cannot" is answered from the registry rather than
  /// re-derived per call site. An agent we do not recognise answers `false`,
  /// which is the same safe default the field itself carries.
  bool allowsConcurrentResume(String agentId) =>
      _ref
          .read(agentRegistryProvider)
          .byId(agentId)
          ?.launch
          .allowsConcurrentResume ??
      false;

  /// What to show the user when we name the agent in a refusal.
  String agentDisplayName(String agentId) =>
      _ref.read(agentRegistryProvider).byId(agentId)?.displayName ?? agentId;

  /// **The** resume decision, for every surface.
  ///
  /// [canReattach] is the caller saying whether reopening our own pane would
  /// satisfy the request. It is false for a handoff to a terminal window we do
  /// not own: there, a live pane of ours is just another process holding the
  /// conversation, and only the agent's capability decides.
  ///
  /// [heldByAnotherProcess] is for callers that have *certain* knowledge of a
  /// holder we do not own — an agent's own refusal, read off its screen (see
  /// `SessionWhereabouts.knownHeldElsewhere`). It is never inferred here.
  ResumeAction resumeActionForConversation({
    required String agentId,
    String? sessionId,
    String? externalSessionId,
    bool canReattach = true,
    bool heldByAnotherProcess = false,
  }) => resumeActionFor(
    weHostItLive: hostedLive(
      sessionId: sessionId,
      externalSessionId: externalSessionId,
    ),
    allowsConcurrentResume: allowsConcurrentResume(agentId),
    heldByAnotherProcess: heldByAnotherProcess,
    canReattach: canReattach,
  );

  /// Whether **we** are running this conversation right now, by either name it
  /// has: one of our session rows, or the CLI's own id.
  ///
  /// Both are needed and neither is enough. An imported entry only knows the CLI
  /// id; a native Codex row often has no CLI id at all, because Codex will not
  /// accept one and it is only discovered afterwards — so a check that used only
  /// the external id silently passed every native Codex session.
  bool hostedLive({String? sessionId, String? externalSessionId}) =>
      livePaneFor(sessionId) != null ||
      runningSessionWithExternalId(externalSessionId) != null;

  /// Throws the plain-words refusal for a handoff the agent forbids, or returns
  /// normally. Shared by the paths that cannot reattach so their message, and
  /// the moment they give up, cannot drift apart.
  void refuseIfForbidden({
    required String agentId,
    String? sessionId,
    String? externalSessionId,
    bool heldByAnotherProcess = false,
  }) {
    final action = resumeActionForConversation(
      agentId: agentId,
      sessionId: sessionId,
      externalSessionId: externalSessionId,
      canReattach: false,
      heldByAnotherProcess: heldByAnotherProcess,
    );
    if (action != ResumeAction.blocked) return;
    final running =
        runningSessionWithExternalId(externalSessionId) ??
        (livePaneFor(sessionId) == null
            ? null
            : _ref.read(sessionDaoProvider).getById(sessionId!));
    throw SessionAlreadyRunning(
      agentName: agentDisplayName(agentId),
      sessionId: running?.id,
      title: running?.title,
    );
  }

  // --- was the conversation ever written? ------------------------------------

  /// The row that **minted** [externalSessionId], or `null` when that id was
  /// read back from the agent rather than handed to it.
  ///
  /// The whole distinction this fix turns on, and it is readable straight off
  /// the data: `launch` assigns a new session *our own row id* as the CLI's
  /// session id (see `assignsOwnId`), so `sessions.id == external_session_id`
  /// is the signature of an id we promised rather than one we observed.
  ///
  /// An observed id — a hook payload, an imported store entry, a discovered
  /// Codex thread — is evidence the conversation existed, and is deliberately
  /// left alone here: the store is the only witness for it, and asking the
  /// store about a conversation the store already told us about would let a
  /// misconfigured `CLAUDE_CONFIG_DIR` retract a fact we had.
  Session? rowThatMinted(String? externalSessionId) {
    if (externalSessionId == null || externalSessionId.isEmpty) return null;
    final row = _ref.read(sessionDaoProvider).getById(externalSessionId);
    return row != null && row.externalSessionId == externalSessionId
        ? row
        : null;
  }

  /// Throws [SessionConversationMissing] when [request] would resume a
  /// conversation the agent's store has read to the end without finding, and
  /// returns normally in every other case — including "we could not tell".
  ///
  /// Also corrects the row on the way out. It said `running` from the moment it
  /// was written, which is the earliest anything *could* have said so and, for
  /// a conversation that was never written, was never true. This is the first
  /// moment the app knows better, so it is the moment to stop the row claiming
  /// otherwise.
  Future<void> refuseIfConversationMissing(SessionLaunchRequest request) async {
    final externalId = request.resumeExternalSessionId;
    if (externalId == null || externalId.isEmpty) return;
    final minted = rowThatMinted(externalId);
    if (minted == null || minted.isArchived) return;
    final descriptor = _ref
        .read(agentRegistryProvider)
        .byId(request.installation.agentId);
    // Expressed through the descriptor, never through an agent's name: an
    // agent that does not take an id from us cannot have made this promise,
    // and its store is asked about nothing.
    if (descriptor == null ||
        !descriptor.launch.sessionIdAssignment.isSupported) {
      return;
    }
    final presence = await _ref.read(conversationPresenceProvider)(
      descriptor: descriptor,
      // Where the agent would have written it: the directory the session runs
      // in decides which environment's store holds the transcript.
      environmentId:
          (minted.workingDirectory ??
                  minted.worktree ??
                  request.repository.path)
              .environmentId,
      conversationId: externalId,
    );
    if (presence != ConversationPresence.absent) return;
    _ref.read(sessionDaoProvider).updateStatus(minted.id, SessionStatus.failed);
    _publish(SessionChange.statusChanged(minted.id));
    throw SessionConversationMissing(
      agentName: agentDisplayName(request.installation.agentId),
      conversationId: externalId,
      sessionId: minted.id,
      title: minted.title,
    );
  }

  /// What to tell the user when [request] continues or forks a conversation
  /// from a directory it was not recorded in, or `null` when there is nothing
  /// to say.
  ///
  /// **This app moves sessions between directories on purpose**, which is why
  /// the question is asked at all:
  ///
  /// * `SessionArchiveService` removes a worktree and keeps the row, so
  ///   `directoryOrFallback` resumes from the repository root instead;
  /// * `SessionHandoffService.forkSession(intoNewWorktree: true)` launches
  ///   `--resume <source> --fork-session` in a worktree the source conversation
  ///   was never started in.
  ///
  /// (A third path was suspected and is not one: `select_checkout` moves the
  /// Explorer's selection through `CheckoutPicker` and never touches a
  /// session's working directory. `session_cwd_rule_test.dart` pins that.)
  ///
  /// A sentence and not a refusal, for the reason [resumeDirectoryCaveatFor]
  /// gives at length: the launch is still the best thing to do, and every other
  /// unknown in this area resolves the permissive way. It is also unreachable
  /// for the three agents shipped today, all of which declare
  /// [AgentResumeLocality.anyDirectory] against evidence.
  String? conversationElsewhereCaveat(
    SessionLaunchRequest request,
    EnvironmentPath launchDirectory,
  ) {
    final conversationId =
        request.resumeExternalSessionId ?? request.forkExternalSessionId;
    if (conversationId == null || conversationId.isEmpty) return null;
    // The row that *holds* this conversation, which for a fork is the source
    // session and not the one being created. Asked of the id rather than of
    // `reused`, because a fork has no reusable row at all.
    final holder = _ref
        .read(sessionDaoProvider)
        .getByExternalSessionId(conversationId);
    final recorded = holder?.workingDirectory ?? holder?.worktree;
    // A row that never recorded a directory (before schema v22) tells us
    // nothing about where the conversation was written, and an unknown earns
    // no sentence.
    if (recorded == null) return null;
    return resumeDirectoryCaveatFor(
      _ref.read(agentRegistryProvider),
      request.installation.agentId,
      conversationId,
      recordedDirectory: recorded.path,
      launchDirectory: launchDirectory.path,
    );
  }

  /// Creates the session row and starts it on the requested surface.
  Future<SessionLaunchResult> launch(SessionLaunchRequest request) async {
    // Before anything is written: a resume of a conversation we are still
    // running would be a second agent on it. Callers that can reopen the running
    // view do so and never get here; this is the backstop for the ones that
    // cannot, and for whatever is added next.
    //
    // It asks the agent rather than refusing outright. Launching is a *create*,
    // so it can never reattach — but for an agent that permits concurrent
    // resume (Claude Code) a second process is exactly what was asked for, and
    // blocking it here refused the one case the user wanted to keep.
    refuseIfForbidden(
      agentId: request.installation.agentId,
      externalSessionId: request.resumeExternalSessionId,
    );

    // And a resume of a conversation the agent never wrote is not a resume at
    // all. Asked here, before anything is written, for the same reason as the
    // refusal above: every surface that continues a session comes through this
    // method, and none of them should have to remember.
    await refuseIfConversationMissing(request);

    // A request cannot both continue and branch one conversation: the two
    // produce different command lines (a resume convention vs a fork one) and
    // honouring either silently would give the user the other thing.
    if (request.resumeExternalSessionId != null &&
        request.forkExternalSessionId != null) {
      throw ArgumentError(
        'A launch cannot both resume and fork a conversation.',
      );
    }

    final depth = depthForChildOf(request.parentSessionId);
    if (!depth.isAllowed) throw SessionDepthRefused(depth);

    final descriptor = _ref
        .read(agentRegistryProvider)
        .byId(request.installation.agentId);
    // A first message an agent cannot be handed is a refusal, not a launch.
    //
    // `agentPaneArguments` drops the prompt when the CLI takes none, and every
    // caller above then reports success: fan-out records the candidate as
    // `started`, and the MCP `spawn` tool answers "opened a new session", so a
    // model believes its instruction landed when the agent came up bare. This
    // was unreachable while Antigravity was discovered under a name nothing
    // installs; correcting that name made it live. Refusing here closes
    // fan-out and MCP together, which is why it is not a guard at either.
    final message = request.firstMessage?.trim();
    if (message != null &&
        message.isNotEmpty &&
        !(descriptor?.launch.acceptsPromptArgument ?? false)) {
      throw SessionLaunchRefused(
        '${descriptor?.displayName ?? request.installation.agentId} takes no '
        'opening message on its command line, so this one would be dropped '
        'without a word. Start it and say it in the session instead.',
      );
    }

    // A resume continues a conversation we may already have a row for. Until
    // Loop 66 it minted a second one every time, so resuming a stopped session
    // left the dead row *and* a new one, both drawn in the tree and both
    // answering to the same CLI id — which is what made the double-writer check
    // above have to choose between rows at all. Reusing is what the imported
    // path has always done by deleting its own record afterwards; the native
    // path had no equivalent.
    //
    // Resolved *before* the permission mode, and that order is the fix for the
    // owner's report — "existing session permission mode should be overridable
    // in each session. but settings is taking precedence". This method used to
    // resolve the mode from the setting alone and then write it over the row it
    // was about to reuse, so every resume silently discarded the mode chosen on
    // the composer chip.
    final reused = _reusableRowForResume(request);

    // What was **decided** for this session, in priority order: a caller that
    // resolved one for this launch (a handoff's carry, a review's cap, an MCP
    // request that named a mode), otherwise the row's own choice. Null means
    // nobody ever chose, and the setting answers — live, so changing it moves
    // this session and every other that never chose.
    final chosenMode =
        request.permissionOverride?.canonical ?? reused?.permissionMode;
    final permissionMode = permissionFor(
      request.installation.agentId,
      request.purpose,
      sessionMode: chosenMode,
    );

    // The same shape one line down, and the same rule: a caller's decision, or
    // the row's own, or — resolved live — the per-agent default. Null all the
    // way down means no model flag at all, which is what every session did
    // before there was a model chip and is still the honest answer.
    final modelId = resolveSessionModel(
      sessionModelId: request.modelOverride ?? reused?.modelId,
      defaultModelId: defaultModelFor(request.installation.agentId),
    ).modelId;

    final id = reused?.id ?? _ref.read(idGeneratorProvider).newId();

    if (request.useWorktree && request.existingWorktree != null) {
      throw ArgumentError(
        'A launch cannot both create a worktree and join an existing one.',
      );
    }

    var workingDirectory = request.repository.path;
    // What to write on the row, which is the launch directory except when we
    // fell back off a directory that has gone away — see below.
    var recordDirectory = true;
    String? workingDirectoryNotice;
    EnvironmentPath? worktree;
    if (request.existingWorktree != null) {
      // Joining, not creating. A handoff and a same-worktree fork continue the
      // work *where it is*, on the branch it is on, so the receiving agent sees
      // the tree the recap describes rather than a clean checkout of the
      // repository root.
      workingDirectory = request.existingWorktree!;
      worktree = request.existingWorktree;
    } else if (request.useWorktree) {
      final created = await _ref
          .read(worktreeServiceProvider)
          .createForSession(
            repo: request.repository.path,
            worktreeName: sessionWorktreeName(id),
            branch: sessionBranchName(id),
          );
      workingDirectory = created.path;
      worktree = created.path;
    } else {
      // Where this conversation was actually running, from the caller when it
      // knows (a handoff, a fork) and otherwise from the row being resumed —
      // which is what makes a resume from the Explorer land in an adopted
      // session's own subdirectory without the Explorer having to say so.
      final resolved = directoryOrFallback(
        _ref,
        // The row's worktree is the same fact for a row written before schema
        // v22, which recorded no directory but did record where it ran. It is
        // read here and not turned into `worktree`: the reused row already
        // carries that, and a launch must not invent one.
        directory:
            request.workingDirectory ??
            reused?.workingDirectory ??
            reused?.worktree,
        fallback: request.repository.path,
      );
      workingDirectory = resolved.directory;
      // Falling back rather than failing: a resume must still happen. The
      // record is kept when we fell back, because a missing folder is often
      // temporary — an unmounted drive, a WSL distro that is not running — and
      // forgetting it would turn that into permanent data loss.
      workingDirectoryNotice = resolved.notice;
      recordDirectory = resolved.notice == null;
    }

    // Asked last, because it is the first thing that can only be answered once
    // the directory is known: is this launch continuing or forking a
    // conversation from somewhere other than where it was recorded, on an agent
    // nobody has verified can find it from there? Joined onto whatever the
    // fallback above already had to say, because both sentences are about the
    // same substitution and the user reads one line.
    workingDirectoryNotice = [
      ?workingDirectoryNotice,
      ?conversationElsewhereCaveat(request, workingDirectory),
    ].join(' ');
    if (workingDirectoryNotice.isEmpty) workingDirectoryNotice = null;

    // A resumed session already has a CLI id. A new one gets *ours* when the
    // agent will accept it — our ids are RFC-4122 v4, which is what
    // `--session-id` wants — so the transcript that backs the chat view is
    // locatable at launch instead of guessed at afterwards. Agents that cannot
    // be told (Codex) keep a null id until something discovers it.
    //
    // A **fork** is a create, not a resume: the CLI is told to start a new
    // conversation seeded from an old one, so it will mint its own id — which
    // is the entire meaning of Claude's `--fork-session`, "create a new session
    // ID instead of reusing the original". So the fork's source id is never
    // recorded as this session's own, and we do not offer ours either: passing
    // `--session-id` alongside `--fork-session` would ask the CLI for a new id
    // and then name the one it must not reuse.
    final assignsOwnId =
        request.resumeExternalSessionId == null &&
        request.forkExternalSessionId == null &&
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

    // Reusing keeps the row's own identity — title, creation time, lineage,
    // worktree — and changes only what a resume actually changes. Rebuilding it
    // from the request would let "continue this session" quietly rename it (the
    // imported path passes the CLI's title) or re-date it.
    final session =
        reused?.copyWith(
          status: SessionStatus.running,
          // `copyWith` keeps the row's own mode when this is null, which is
          // the point: a resume must not overwrite a choice, and must not
          // freeze a session that never made one.
          permissionMode: request.permissionOverride?.canonical,
          modelId: request.modelOverride,
          workingDirectory: recordDirectory ? workingDirectory : null,
        ) ??
        Session(
          id: id,
          repositoryId: request.repository.id,
          agentInstallationId: request.installation.id,
          title: request.title.trim().isEmpty
              ? 'Session'
              : request.title.trim(),
          // True for a joined worktree as well as a created one: the row says
          // where this session runs, and it does run in a worktree.
          useWorktree: request.useWorktree || worktree != null,
          worktree: worktree,
          // The directory the process is about to be started in — a fact, and
          // the same one an adopted session records. Two sources for it would
          // drift.
          workingDirectory: recordDirectory ? workingDirectory : null,
          status: SessionStatus.running,
          createdAt: _ref.read(clockProvider).nowUtc(),
          externalSessionId: externalSessionId,
          parentSessionId: request.parentSessionId,
          // A parent with no stated reason is a spawn — the only way a session
          // could acquire one before schema v13, and what the MCP path still means
          // when it names a caller without saying more.
          parentLink: request.parentSessionId == null
              ? null
              : (request.parentLink ?? SessionLink.spawn),
          surface: request.surface,
          view: request.view ?? defaultViewFor(descriptor),
          // Only what was **chosen**, which for an ordinary launch is nothing.
          // Stamping the resolved default here read as a per-session decision
          // afterwards, so every session was frozen at whatever Settings
          // happened to say on the day it started and changing the default
          // moved nothing — the opposite half of the owner's report. The
          // effective mode is not lost by leaving this null: it is
          // [resolveSessionPermission] of this row and the live setting, which
          // is the same answer the chip and the next launch compute.
          permissionMode: request.permissionOverride?.canonical,
          // Only what was **chosen**, for the reason above: a launch that
          // stamped the resolved model here would freeze this session on
          // whichever model Settings named today.
          modelId: request.modelOverride,
        );
    final dao = _ref.read(sessionDaoProvider);
    if (reused == null) {
      dao.insert(session);
    } else {
      dao.updateStatus(id, SessionStatus.running);
      // Written only when this launch carries a decision. Writing the resolved
      // mode unconditionally is what destroyed the chip's choice on the next
      // resume, and it would also stamp a default onto a session that is
      // deliberately following one.
      if (request.permissionOverride != null) {
        dao.updatePermissionMode(id, request.permissionOverride!.canonical);
      }
      if (request.modelOverride != null) {
        dao.updateModel(id, request.modelOverride);
      }
      if (recordDirectory) dao.updateWorkingDirectory(id, workingDirectory);
    }
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
          modelId,
          workingDirectory,
          assignsOwnId,
          firstMessage,
          workingDirectoryNotice,
        ),
        SessionSurface.external => await _startInExternalTerminal(
          session,
          request,
          descriptor,
          permissionMode,
          modelId,
          workingDirectory,
          assignsOwnId,
          firstMessage,
          workingDirectoryNotice,
        ),
      };
      _publish(_whatALaunchMoved(request, id, reused: reused != null));
      return result;
    } catch (_) {
      // The row must not outlive a launch that never happened — that is exactly
      // the "session created as a side effect nothing observes" the audit found,
      // wearing the opposite hat.
      dao.updateStatus(id, SessionStatus.failed);
      // The same word as the success path: the row still appeared, and it is
      // still this one row that moved. A failed launch must reach every list
      // that draws it, and nothing else.
      _publish(_whatALaunchMoved(request, id, reused: reused != null));
      rethrow;
    }
  }

  /// What a launch actually moved, named rather than shouted.
  ///
  /// This used to be a bare `bump()` — [SessionChange.everything], the word for
  /// a caller that cannot say what changed. A launch can: one row appeared,
  /// started, and claimed a pane. The difference is the whole of the owner's
  /// *"starting new session is heavy and laggy too"*, because the coarse word
  /// raises `SessionSignals.broadcasts`, which is the floor under **every**
  /// per-row watcher — and the Explorer builds one
  /// [sessionWhereaboutsProvider] per drawn card. So creating one session
  /// re-read every session's row and re-scanned the screen of every dead pane,
  /// synchronously, on the UI isolate, inside the frame:
  /// `session_start_cost_test.dart` measured 158 statements, 35 screen scans
  /// and 39 rebuilds at a hundred sessions against 26, 2 and 6 at one.
  ///
  /// Naming the row leaves `broadcasts` alone, so the ninety-nine cards that
  /// did not change stay asleep. Every kind that any watcher of the *list*
  /// reads is still published, which is what keeps the new row appearing
  /// everywhere it must — see the second half of that test.
  SessionChange _whatALaunchMoved(
    SessionLaunchRequest request,
    String id, {
    required bool reused,
  }) => SessionChange(
    sessionId: id,
    kinds: {
      // A create grows the list. A resume reuses a row already in it — but
      // every watcher of the list watches membership anyway, so this is the
      // only kind the two cases differ on.
      if (!reused) SessionChangeKind.membership,
      SessionChangeKind.status,
      // The row claimed a pane, and a new session was just given its
      // conversation id — which is what hides the imported record for it.
      SessionChangeKind.placement,
      // Only a launch that carried a decision wrote a per-session policy.
      if (request.permissionOverride != null || request.modelOverride != null)
        SessionChangeKind.settings,
      // A created worktree is a checkout the picker has to start offering,
      // and the picker watches nothing else.
      if (request.useWorktree) SessionChangeKind.workspace,
    },
  );

  /// The row [request] should continue rather than duplicate, or `null` when
  /// this launch genuinely creates a session.
  ///
  /// Narrow on purpose — every condition below is a case where two rows is the
  /// honest answer:
  ///
  /// * **Not a resume.** A create is a create; a fork is a create too (the CLI
  ///   mints a new conversation id, so it cannot collide with an existing row).
  /// * **A new worktree.** The row records *where* a session runs, so moving the
  ///   conversation into a fresh checkout earns its own row.
  /// * **A stated parent.** A parented launch is asserting a new relationship,
  ///   and reuse would silently drop it.
  /// * **A live candidate.** `refuseIfForbidden` has already let this through,
  ///   which for an agent that permits concurrent resume means a second process
  ///   on the conversation was the point. That is a second session, not a
  ///   re-entry into the first — and overwriting a live row's pane id would lose
  ///   the process we are still holding.
  /// * **A different repository, installation or surface.** Same conversation,
  ///   different thing being run; the row would stop describing its own session.
  /// * **Archived.** Its worktree is gone; reviving it would point a live agent
  ///   at a directory that no longer exists.
  Session? _reusableRowForResume(SessionLaunchRequest request) {
    final externalId = request.resumeExternalSessionId;
    if (externalId == null || externalId.isEmpty) return null;
    if (request.useWorktree || request.parentSessionId != null) return null;
    for (final candidate
        in _ref
            .read(sessionDaoProvider)
            .getAllByExternalSessionId(externalId)) {
      if (candidate.isArchived) continue;
      if (candidate.repositoryId != request.repository.id) continue;
      if (candidate.agentInstallationId != request.installation.id) continue;
      if (candidate.surface != request.surface) continue;
      if (livePaneFor(candidate.id) != null) continue;
      return candidate;
    }
    return null;
  }

  SessionLaunchResult _startInPane(
    Session session,
    SessionLaunchRequest request,
    AgentDescriptor? descriptor,
    PermissionSelection permissionMode,
    String? modelId,
    EnvironmentPath workingDirectory,
    bool assignsOwnId,
    String? firstMessage,
    String? workingDirectoryNotice,
  ) {
    final environment = _ref
        .read(executionEnvironmentDaoProvider)
        .getById(workingDirectory.environmentId);
    if (environment == null) {
      throw StateError('The repository\'s environment is unavailable.');
    }
    final mcp = _mcpAccessFor(session, descriptor, environment);
    final launch = AgentPaneLaunch(
      agentId: request.installation.agentId,
      executable: request.installation.executable.path,
      // The two halves are kept apart on the record rather than joined into one
      // list: this is the launch the pane is *stored* as, and the MCP flags are
      // dead the moment this app process is. `commandArguments` puts them back
      // together in the order the agents want.
      arguments: agentPaneArguments(
        descriptor,
        permissionMode,
        modelId: modelId,
        sessionId: assignsOwnId ? session.id : null,
        resumeSessionId: request.resumeExternalSessionId,
        forkSessionId: request.forkExternalSessionId,
        prompt: firstMessage,
      ),
      mcpArguments: agentMcpArguments(
        descriptor,
        url: mcp?.url,
        configPath: mcp?.configPath,
      ),
      workingDirectory: workingDirectory.path,
      wslDistribution: environment.wslDistribution,
      sessionId: session.id,
      title: session.title,
    );
    final terminals = _ref.read(terminalSessionsControllerProvider.notifier);
    // A session whose pane was restored but never started already has a
    // terminal: the one holding everything it printed before the app was last
    // closed. Running the resume *in* it continues that record, where opening a
    // second pane would leave the user two terminals for one session — the
    // dormant one the workbench shows, and a live one beside it.
    //
    // Only a dormant pane. `reveal` has already brought back a live one, and an
    // exited pane is this run's record of a process that stopped rather than
    // history waiting to be continued.
    final dormant = dormantPaneFor(session.id);
    final resumedTab = dormant == null
        ? null
        : terminals.startAgentInPane(dormant, launch);
    final opened = resumedTab == null
        ? terminals.openAgentTab(launch)
        : (tabId: resumedTab, paneId: dormant!);
    _ref.read(sessionDaoProvider).updatePaneId(session.id, opened.paneId);
    _ref.read(terminalVisibleProvider.notifier).set(true);
    // Deliberately after the pane is claimed, so it reports what happened
    // rather than what was intended. `resumed` is the dormant-pane reuse: when
    // it is false for a session that has a restored pane, the user is about to
    // be looking at two terminals for one session.
    _log.info(
      'Started ${session.id} in a pane: agent=${request.installation.agentId} '
      'mode=${permissionMode.canonical} model=${modelId ?? 'agent default'} '
      'pane=${opened.paneId} '
      'resumed=${resumedTab != null} '
      'conversation=${request.resumeExternalSessionId ?? 'new'} '
      'worktree=${request.useWorktree} '
      // The ordinary answer is often "none" and that is not an error — but it
      // is the answer to "why can't the agent see Karmashala's tools", which
      // was previously only discoverable by reading the launched command line.
      'mcp=${mcp == null ? 'none' : 'yes'}',
    );
    return SessionLaunchResult(
      session: session.copyWith(paneId: opened.paneId),
      paneId: opened.paneId,
      tabId: opened.tabId,
      workingDirectoryNotice: workingDirectoryNotice,
    );
  }

  Future<SessionLaunchResult> _startInExternalTerminal(
    Session session,
    SessionLaunchRequest request,
    AgentDescriptor? descriptor,
    PermissionSelection permissionMode,
    String? modelId,
    EnvironmentPath workingDirectory,
    bool assignsOwnId,
    String? firstMessage,
    String? workingDirectoryNotice,
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
    final mcp = _mcpAccessFor(session, descriptor, environment);
    final agentCommand = [
      request.installation.executable.path,
      ...agentPaneArguments(
        descriptor,
        permissionMode,
        modelId: modelId,
        sessionId: assignsOwnId ? session.id : null,
        resumeSessionId: request.resumeExternalSessionId,
        forkSessionId: request.forkExternalSessionId,
        prompt: firstMessage,
        mcpUrl: mcp?.url,
        mcpConfigPath: mcp?.configPath,
      ),
    ];
    final distro = environment.wslDistribution;
    // Same wrapper decision as the pane and the resume paths, from the same
    // function: the environment says whether the line has to cross into WSL.
    final command = wrapForExternalTerminal(
      ShellCommand(
        executable: agentCommand.first,
        arguments: agentCommand.sublist(1),
        workingDirectory: workingDirectory.path,
      ),
      LaunchContext.forEnvironment(distro),
    );
    await _ref
        .read(systemTerminalServiceProvider)
        .launch(
          terminal,
          command: command,
          workingDirectory: distro == null ? workingDirectory.path : null,
        );
    return SessionLaunchResult(
      session: session,
      workingDirectoryNotice: workingDirectoryNotice,
    );
  }

  /// How this session will reach Karmashala's own tools, or `null` when it
  /// will not.
  ///
  /// Both surfaces call this and then hand the result to [agentPaneArguments],
  /// which is the same reason they share that function: "open this in Windows
  /// Terminal instead" must produce the same agent, on the same endpoint,
  /// speaking as the same session.
  ///
  /// `null` is the ordinary answer and never an error. The control server is
  /// not up; the agent has no verified convention; the session runs over SSH,
  /// or in WSL on a host with no switch to dial; the config directory could not
  /// be locked down. In every case the launch is byte-identical to the one that
  /// happened before any of this existed — which is the property that matters
  /// most, because a session that opens without its tools is a smaller loss
  /// than a session that does not open.
  SessionMcpAccess? _mcpAccessFor(
    Session session,
    AgentDescriptor? descriptor,
    ExecutionEnvironment environment,
  ) => sessionMcpAccessFor(
    _ref,
    sessionId: session.id,
    descriptor: descriptor,
    environment: environment,
  );

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
    final terminal = _liveTerminalFor(sessionId);
    if (terminal == null) return false;
    // A carriage return, not a newline: a PTY line discipline reads CR as
    // "submit", and a bare LF leaves the text sitting in the agent's composer.
    terminal
      ..textInput(trimmed)
      ..textInput('\r');
    return true;
  }

  /// Answers an agent's on-screen prompt by pressing [keys] in its terminal.
  ///
  /// Separate from [sendTo] rather than a special case of it, because the two
  /// are different acts. [sendTo] delivers a *message*: it trims, refuses empty
  /// input and appends a carriage return to submit it. An answer is a
  /// **keystroke** — `\r`, `\x1b` — where trimming would erase the whole
  /// payload and an appended return would press a second key nobody asked for.
  ///
  /// [keys] must come from the agent's own [AgentApprovalRules]. Nothing here
  /// invents a binding: this method presses what it is given, and the registry
  /// is what decides whether there is anything to press.
  ///
  /// Returns false when the session has no live pane, so the caller can say the
  /// answer did not land instead of assuming it did.
  ///
  /// **This is where an approval reaches the decision record**, and it is the
  /// only place both answering paths meet: the approval card presses these
  /// keys and so does `session_answer`. Recording here means the packet carries
  /// what the user allowed however they allowed it, rather than only what came
  /// through the bridge.
  ///
  /// [decidedBy] names who answered — the user by default, since the card is
  /// the ordinary route; `session_answer` passes the agent that called it.
  bool answerPrompt(
    String sessionId,
    String keys, {
    String decidedBy = 'the user',
    String? decidedBySessionId,
  }) {
    if (keys.isEmpty) return false;
    final terminal = _liveTerminalFor(sessionId);
    if (terminal == null) return false;
    terminal.textInput(keys);
    _recordAnswer(
      sessionId,
      keys,
      decidedBy: decidedBy,
      decidedBySessionId: decidedBySessionId,
    );
    return true;
  }

  /// Writes the answered prompt to the session's decision record, when the
  /// keystroke is one the agent itself named.
  ///
  /// **A table lookup, not an interpretation.** [keys] is matched against the
  /// agent's own [AgentApprovalRules] — the same table the card read to draw
  /// the button — so what is recorded is the agent's own words for what that
  /// key does. Keys that match neither answer record *nothing*: this method
  /// also carries whatever an agent's prompt was answered with by some other
  /// route, and guessing at what an unrecognised keystroke authorised is
  /// exactly the inference the record must never contain.
  void _recordAnswer(
    String sessionId,
    String keys, {
    required String decidedBy,
    required String? decidedBySessionId,
  }) {
    final session = _ref.read(sessionDaoProvider).getById(sessionId);
    if (session == null) return;
    final agentId = _ref
        .read(agentInstallationDaoProvider)
        .getById(session.agentInstallationId)
        ?.agentId;
    if (agentId == null) return;
    final rules =
        _ref.read(agentRegistryProvider).byId(agentId)?.approval ??
        const AgentApprovalRules();
    final granted = rules.approve?.keys == keys;
    final answer = granted ? rules.approve : rules.deny;
    if (answer == null || answer.keys != keys) return;
    _ref
        .read(decisionRecorderProvider)
        .recordApproval(
          sessionId: sessionId,
          granted: granted,
          effect: answer.effect,
          answerLabel: answer.label,
          decidedBy: decidedBy,
          decidedBySessionId: decidedBySessionId,
        );
  }

  /// The live terminal behind [sessionId], or null. Three things have to be
  /// true and each has been wrong on its own — see [livePaneFor].
  Terminal? _liveTerminalFor(String sessionId) {
    final paneId = _ref.read(sessionDaoProvider).getById(sessionId)?.paneId;
    if (paneId == null) return null;
    final instance = _ref
        .read(terminalSessionsControllerProvider.notifier)
        .instanceFor(paneId);
    if (instance == null || !instance.liveness.value.isLive) return null;
    return instance.terminal;
  }

  void _publish(SessionChange change) =>
      _ref.read(sessionsRevisionProvider.notifier).changed(change);
}

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

final sessionLauncherProvider = Provider<SessionLauncher>(
  (ref) => SessionLauncher(ref),
);
