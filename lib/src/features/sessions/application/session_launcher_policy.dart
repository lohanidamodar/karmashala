part of 'session_launcher.dart';

/// **Permission mode and model, resolved here and nowhere else.**
///
/// Loop 33's audit found permission mode resolved in eight places with three
/// different answers; the model chip was built to the shape that came out of
/// fixing it. Both now follow the same three rules, which is why they are one
/// file: what a caller decided wins, then what the row itself chose, then —
/// read live, never captured — the per-agent default. A session that never
/// chose moves when the setting moves.
///
/// The reads and the writes are together on purpose. What a chip *shows* and
/// what a launch *passes* come out of one call rather than two call sites that
/// agree today: `effectivePermissionFor` and `effectiveModelFor` are the
/// launch path answering the question early, and `liveModelSwitchBlockerFor`
/// is what keeps a control's promise and its outcome from disagreeing.
///
/// An extension in a `part` for the reason `session_launcher.dart` gives.
extension SessionPolicyVerbs on SessionLauncher {
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
