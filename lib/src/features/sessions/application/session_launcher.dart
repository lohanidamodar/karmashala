import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

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
import '../../settings/application/settings_controller.dart';
import '../../settings/domain/permission_mode.dart';
import '../../terminal/application/system_terminal_providers.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import '../../terminal/data/pty_launch.dart';
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
import '../domain/session_resume.dart';
import '../domain/session_status.dart';
import 'decision_recorder.dart';
import 'session_providers.dart';
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
  /// but it is the one thing the user must be told, because a resume in the
  /// wrong directory is how an agent CLI quietly opens a new conversation
  /// rather than the one that was asked for.
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
  /// rather than a limitation of Chitragupta.
  final String agentName;

  @override
  String toString() {
    final where = title == null
        ? 'That conversation is already open in another process.'
        : '"$title" is already running in Chitragupta.';
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
  ///
  /// **[sessionMode] wins when it is set.** That is `Session.permissionMode`,
  /// stamped at launch and rewritten by the composer control, and it is why the
  /// per-agent setting keeps its two values without either of them being able
  /// to overwrite a session's own choice later. A caller holding a session row
  /// passes it; one that has no session yet (a shell command for a project, a
  /// brand-new launch) leaves it null and gets the default for [purpose].
  ///
  /// Null [sessionMode] on an *existing* row means the row predates schema v11,
  /// so the setting is the only answer anyone ever had for it.
  PermissionMode permissionFor(
    String agentId,
    SessionPurpose purpose, {
    PermissionMode? sessionMode,
  }) {
    if (sessionMode != null) return sessionMode;
    final permissions = _ref
        .read(settingsControllerProvider)
        .permissionsFor(agentId);
    return switch (purpose) {
      SessionPurpose.newSession => permissions.newSessions,
      SessionPurpose.existingSession => permissions.existingSessions,
    };
  }

  /// The mode [sessionId] will run under on its next launch or resume, and the
  /// agent it will be handed to.
  ///
  /// The read behind the composer control, so what the chip shows and what the
  /// launcher passes come from one place by construction rather than by two
  /// call sites agreeing.
  ({PermissionMode mode, AgentDescriptor? descriptor, bool inherited})?
  effectivePermissionFor(String sessionId) {
    final session = _ref.read(sessionDaoProvider).getById(sessionId);
    if (session == null) return null;
    final installation = _ref
        .read(agentInstallationDaoProvider)
        .getById(session.agentInstallationId);
    if (installation == null) return null;
    return (
      mode: permissionFor(
        installation.agentId,
        SessionPurpose.existingSession,
        sessionMode: session.permissionMode,
      ),
      descriptor: _ref.read(agentRegistryProvider).byId(installation.agentId),
      inherited: session.permissionMode == null,
    );
  }

  /// Records the mode [sessionId] should run under from its next launch on.
  ///
  /// Deliberately **does not touch the running process**. Every agent here
  /// takes its permission policy from its command line at startup; none of them
  /// has a documented way to be told a new one mid-session, and typing a slash
  /// command at whatever has focus would be a guess about another program's
  /// UI. So this writes the row, and the control says the change applies on the
  /// next launch rather than implying the live agent has been re-governed.
  void setPermissionMode(String sessionId, PermissionMode mode) {
    _ref.read(sessionDaoProvider).updatePermissionMode(sessionId, mode);
    _bump();
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
    _bump();
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
    _bump();
    throw SessionConversationMissing(
      agentName: agentDisplayName(request.installation.agentId),
      conversationId: externalId,
      sessionId: minted.id,
      title: minted.title,
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

    final permissionMode =
        request.permissionOverride ??
        permissionFor(request.installation.agentId, request.purpose);

    // A resume continues a conversation we may already have a row for. Until
    // Loop 66 it minted a second one every time, so resuming a stopped session
    // left the dead row *and* a new one, both drawn in the tree and both
    // answering to the same CLI id — which is what made the double-writer check
    // above have to choose between rows at all. Reusing is what the imported
    // path has always done by deleting its own record afterwards; the native
    // path had no equivalent.
    final reused = _reusableRowForResume(request);
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
          permissionMode: permissionMode,
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
          // Stamped, not left null. The mode was already resolved above and then
          // died with the local that held it, so nothing could say what a running
          // session was running under — the exact question a control showing the
          // *effective* mode has to answer. Recording it here also means a later
          // resume runs under the session's own mode rather than re-reading a
          // global default that may have changed since.
          permissionMode: permissionMode,
        );
    final dao = _ref.read(sessionDaoProvider);
    if (reused == null) {
      dao.insert(session);
    } else {
      dao
        ..updateStatus(id, SessionStatus.running)
        ..updatePermissionMode(id, permissionMode);
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
          workingDirectory,
          assignsOwnId,
          firstMessage,
          workingDirectoryNotice,
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
    PermissionMode permissionMode,
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
      arguments: agentPaneArguments(
        descriptor,
        permissionMode,
        sessionId: assignsOwnId ? session.id : null,
        resumeSessionId: request.resumeExternalSessionId,
        forkSessionId: request.forkExternalSessionId,
        prompt: firstMessage,
        mcpUrl: mcp?.url,
        mcpConfigPath: mcp?.configPath,
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
    PermissionMode permissionMode,
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

  /// How this session will reach Chitragupta's own tools, or `null` when it
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
  ) {
    try {
      final mcp = _ref.read(sessionMcpProvider);
      final support = descriptor?.launch.mcp;
      if (mcp == null || support == null || !support.isSupported) return null;
      return mcp.accessFor(
        sessionId: session.id,
        environment: environment,
        withConfigFile: support.needsConfigFile,
      );
    } on Object {
      // Wiring an agent to the tool surface is an enhancement. Nothing about it
      // is worth failing a launch over, so the one thing this must not do is
      // throw into the caller.
      return null;
    }
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

  void _bump() => _ref.read(sessionsRevisionProvider.notifier).bump();
}

/// The interactive command-line arguments for one agent launch.
///
/// Shared by the pane and external-terminal surfaces so the two cannot drift:
/// "open this in Windows Terminal instead" must produce the same agent, in the
/// same mode, on the same conversation.
///
/// Order matters and is the order the shipped agents want: the MCP flag, then
/// global flags, then the session-id flag, then the resume convention (which
/// for Codex is a *subcommand* and must follow the globals), then the prompt as
/// a positional argument.
/// [forkSessionId] **replaces** the resume convention rather than adding to it:
/// Codex forks with a `fork` subcommand *instead of* `resume`, and emitting
/// both would put two subcommands on one command line. Claude's fork is its own
/// resume plus `--fork-session`, which its [AgentForkSupport] states, so both
/// shapes come out of one call.
List<String> agentPaneArguments(
  AgentDescriptor? descriptor,
  PermissionMode permissionMode, {
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
    if (mcpUrl != null && mcpUrl.isNotEmpty)
      ...?launch?.mcp.argumentsFor(url: mcpUrl, configPath: mcpConfigPath),
    ...?launch?.permissionArgumentsFor(permissionMode),
    if (sessionId != null && resumeSessionId == null && !forking)
      ...?launch?.sessionIdAssignment.argumentsFor(sessionId),
    if (forking) ...?launch?.fork.argumentsFor(forkSessionId),
    if (!forking && resumeSessionId != null && resumeSessionId.isNotEmpty)
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
