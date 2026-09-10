part of 'session_launcher.dart';

/// The one permission/model resolution: a caller's choice wins, then the
/// session row's, then the per-agent default — read live, never captured.
extension SessionPolicyVerbs on SessionLauncher {
  /// Which stored preference wins, then what that string means to this agent;
  /// `sessionMode` null means "no session yet — use the default for [purpose]".
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
  /// agent it will be handed to — the read behind the composer control, so the
  /// chip and the launcher cannot disagree. `inherited` means the session made
  /// no choice and is tracking the setting live.
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
    // of. `resolveStored` substitutes the agent's default, which is all it can
    // do — but doing that silently would be the claim this area exists to
    // remove.
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
  /// Deliberately **does not touch the running process**: every agent here
  /// takes its permission policy from its command line at startup, and none has
  /// a documented way to be told a new one mid-session. [restartSession] is the
  /// one thing that can move a running session onto a new policy, and it stays
  /// a separate call because ending an agent that may be mid-turn must never be
  /// a side effect of recording a choice.
  void setPermissionMode(String sessionId, PermissionSelection? selection) {
    _ref
        .read(sessionDaoProvider)
        .updatePermissionMode(sessionId, selection?.canonical);
    // One row's own policy. Only the chip that draws it is watching.
    _publish(SessionChange.reconfigured(sessionId));
  }

  /// The default model for [agentId], for a session that has not chosen one —
  /// the Settings preference read **live**, so a session that never chose moves
  /// when the setting moves. Null is still an answer, and the shipped one: "let
  /// the agent choose" passes no model flag, and inventing a name would claim a
  /// session runs on a model nothing was ever passed to select.
  String? defaultModelFor(String agentId) =>
      _ref.read(settingsControllerProvider).defaultModelFor(agentId);

  /// The model [sessionId] will run on at its next launch or resume, and the
  /// agent it will be handed to — [effectivePermissionFor]'s twin, for the same
  /// reason. `inherited` means the session made no choice. A null `modelId` is
  /// an answer, not a gap: no model flag is passed. `defaultModelId` comes out
  /// of this same call because the menu has to name what "follow the default"
  /// resolves to, and a second read of the setting could disagree with it.
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
  /// when it would. Asked twice — the menu badges each row `now` or `next
  /// launch`, and [setModel] says what actually happened — and answered once,
  /// so a control's promise and its outcome cannot disagree. It says nothing
  /// about *which* model; that answer belongs to [setModel], which knows what
  /// was picked.
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
  /// The order of the gates is the design: the row is written first, always, so
  /// a live switch cannot be undone by the next restart; the target is resolved
  /// after the write, so "follow the default" switches to what the default
  /// names (one that names nothing is [ModelDeferral.noModel], not a failure);
  /// the agent must have an in-session command taking a model name, read off
  /// its descriptor and never its name (Codex's `/model` is a picker); and the
  /// session must be running and idle, because a line typed into a pane that is
  /// mid-turn lands in the user's own conversation — `unknown` counts as busy.
  ///
  /// Returns which of the two happened so the caller can *say so*.
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
    // Through [sendTo] rather than a second write path: a slash command must be
    // submitted exactly the way a message is — `\r`, because a PTY line
    // discipline reads a bare newline as text and leaves it in the composer.
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

/// Why a model change could not reach the session running now. Four reasons
/// rather than a bool, because the chip has to say which one: "the agent is
/// mid-turn" is a *wait a moment*, "this CLI takes its model from the command
/// line" is a *never*, and the wrong one sends a user looking for a setting
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
