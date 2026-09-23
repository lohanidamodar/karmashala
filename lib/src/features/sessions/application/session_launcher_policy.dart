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
    final defaults = _ref
        .read(settingsControllerProvider)
        .permissionsFor(agentId);
    final stored = resolveSessionPermission(
      sessionMode: sessionMode,
      newSessionDefault: defaults.newSessions,
      existingSessionDefault: defaults.existingSessions,
      purpose: purpose,
    ).stored;
    final support = _ref
        .read(agentRegistryProvider)
        .byId(agentId)
        ?.launch
        .permission;
    return support?.resolveStored(stored) ?? PermissionSelection.empty;
  }

  /// The same, already turned into the flags a launch passes.
  ResolvedPermission resolvedPermissionFor(
    String agentId,
    SessionPurpose purpose, {
    String? sessionMode,
  }) {
    final support = _ref
        .read(agentRegistryProvider)
        .byId(agentId)
        ?.launch
        .permission;
    if (support == null || !support.isKnown) return ResolvedPermission.none;
    return ResolvedPermission.of(
      support,
      permissionFor(agentId, purpose, sessionMode: sessionMode),
    );
  }

  /// The mode [sessionId] will run under next, behind the composer control, so
  /// chip and launcher cannot disagree. `inherited` means it made no choice.
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
    final defaults = _ref
        .read(settingsControllerProvider)
        .permissionsFor(installation.agentId);
    final resolved = resolveSessionPermission(
      sessionMode: session.permissionMode,
      newSessionDefault: defaults.newSessions,
      existingSessionDefault: defaults.existingSessions,
      purpose: SessionPurpose.existingSession,
    );
    final descriptor = _ref
        .read(agentRegistryProvider)
        .byId(installation.agentId);
    final support = descriptor?.launch.permission;
    // A row written by a newer build can name a value this one never heard of;
    // `resolveStored` substitutes the default, and saying so is the point.
    final stored = PermissionSelection.parse(resolved.stored);
    return (
      selection:
          support?.resolveStored(resolved.stored) ?? PermissionSelection.empty,
      descriptor: descriptor,
      inherited: resolved.followsDefault,
      unrecognised: (support?.unknownAxes(stored) ?? const []).isNotEmpty,
    );
  }

  /// Records the mode [sessionId] runs under from its next launch on; a null
  /// [selection] follows the per-agent default. Never touches a live process.
  void setPermissionMode(String sessionId, PermissionSelection? selection) {
    _ref
        .read(sessionDaoProvider)
        .updatePermissionMode(sessionId, selection?.canonical);
    // One row's own policy. Only the chip that draws it is watching.
    _publish(SessionChange.reconfigured(sessionId));
  }

  /// The default model for [agentId], read **live**, so a session that never
  /// chose moves with the setting. Null passes no flag, which is an answer.
  String? defaultModelFor(String agentId) =>
      _ref.read(settingsControllerProvider).defaultModelFor(agentId);

  /// The model [sessionId] will run on next, plus what "follow the default"
  /// resolves to today — one call, so a second read cannot disagree with it.
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
  /// when it would. Answered once, so badge and [setModel] cannot disagree.
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

  /// Records the model [sessionId] should run on and, **only where that is
  /// safe**, moves the running session too; says which of the two happened.
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
    final picker = effective?.descriptor?.launch.model.pickerCommand ?? '';
    if (blocker == ModelDeferral.noCommand &&
        picker.isNotEmpty &&
        livePaneFor(sessionId) != null &&
        _ref.read(sessionActivityLookupProvider)(sessionId) ==
            AgentActivityStatus.idle &&
        sendTo(sessionId, picker)) {
      // Its own picker, open in the pane: the person finishes the switch there,
      // and the recorded model still applies to every later launch.
      return (
        switchedNow: false,
        command: picker,
        deferral: ModelDeferral.openedPicker,
      );
    }
    if (blocker == ModelDeferral.busy) {
      // Mid-turn is a wait, not a relaunch: sent the moment it is idle again.
      _ref.read(pendingLiveSwitchesProvider).hold(sessionId);
    }
    if (blocker != null) {
      return (switchedNow: false, command: null, deferral: blocker);
    }
    final command = effective?.descriptor?.launch.model.commandFor(target);
    // Through [sendTo] rather than a second write path: a slash command needs
    // the same `\r` a message does, or it sits in the composer.
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

  /// Moves the running session onto the model it is recorded to run on, when
  /// that is safe now. Answers the line sent, or null when nothing was.
  String? switchModelNow(String sessionId) {
    final target = effectiveModelFor(sessionId);
    final modelId = target?.modelId;
    if (modelId == null || liveModelSwitchBlockerFor(sessionId) != null) {
      return null;
    }
    final command = target?.descriptor?.launch.model.commandFor(modelId);
    if (command == null || !sendTo(sessionId, command)) return null;
    _log.info('Switched $sessionId to $modelId after its turn with "$command"');
    return command;
  }
}

/// Why a model change could not reach the session running now — four reasons
/// and not a bool, because "mid-turn" is a wait and "no such flag" is a never.
enum ModelDeferral {
  /// Nothing of ours is running this session.
  notRunning,

  /// The agent is mid-turn, holding a prompt, or in a state no source can
  /// vouch for. A line typed into any of those lands in the user's own input,
  /// so the change is held and sent when the session is next idle.
  busy,

  /// The agent has no in-session command that takes a model name. Codex's
  /// `/model` opens a picker, which is not the same thing.
  noCommand,

  /// The agent's own model picker was opened in the running session, since it
  /// cannot be told a model by name there. The person chooses in it.
  openedPicker,

  /// Nothing to switch *to*: the session was handed back to a default that
  /// names no model, so the agent's own default applies from the next launch.
  noModel,
}
