part of 'session_launcher.dart';

/// What became of moving a running session's permission mode.
enum LivePermissionOutcome {
  /// The agent's screen now shows the mode that was asked for.
  switched,

  /// The agent's own permission picker is open in the pane; the person chooses.
  openedPicker,

  /// The agent has a prompt open; the change is sent once it is answered.
  held,

  /// The cycle came round without showing that mode: this session does not
  /// offer it, so it applies from the next launch. Left as it was found.
  notOffered,

  /// The agent never redrew its mode after a step, so nothing more was pressed.
  noAnswer,

  /// No running session, or no way to move one; the next launch applies it.
  nextLaunch,
}

/// Moves a running session's permission mode without relaunching it, where the
/// agent's descriptor says how, and says what actually happened.
extension SessionLivePermission on SessionLauncher {
  Future<LivePermissionOutcome> switchPermissionLive(
    String sessionId, {
    Duration settle = kPermissionCycleSettle,
  }) async {
    final effective = effectivePermissionFor(sessionId);
    final support = effective?.descriptor?.launch.permission;
    if (effective == null ||
        support == null ||
        livePaneFor(sessionId) == null) {
      return LivePermissionOutcome.nextLaunch;
    }
    final status = activityOf(sessionId);
    final live = support.live;
    if (live != null) {
      final target = support
          .normalise(effective.selection)
          .valueFor(live.axisId);
      if (target == null || !live.reachable.contains(target)) {
        return LivePermissionOutcome.nextLaunch;
      }
      // The cycle key works mid-turn too; only an open prompt could take it
      // as an answer, so that alone waits.
      if (status == AgentActivityStatus.awaitingApproval) {
        _ref.read(pendingLiveSwitchesProvider).holdPermission(sessionId);
        return LivePermissionOutcome.held;
      }
      final outcome = await _cycleTo(sessionId, live, target, settle);
      _log.info('Permission mode of $sessionId → $target: ${outcome.name}');
      return outcome;
    }
    final idle = status == AgentActivityStatus.idle;
    if (support.pickerCommand.isNotEmpty &&
        idle &&
        sendTo(sessionId, support.pickerCommand)) {
      return LivePermissionOutcome.openedPicker;
    }
    return LivePermissionOutcome.nextLaunch;
  }

  /// Steps the cycle in this session's pane until its screen shows [target]
  /// ([cyclePermissionTo], the session host's own way too).
  Future<LivePermissionOutcome> _cycleTo(
    String sessionId,
    AgentPermissionLiveCycle live,
    String target,
    Duration settle,
  ) async {
    final outcome = await cyclePermissionTo(
      live,
      target,
      read: () {
        final terminal = _liveTerminalFor(sessionId);
        return terminal == null ? null : live.read(terminalTailLines(terminal));
      },
      press: () => pressKeys(sessionId, live.key),
      settle: settle,
    );
    return switch (outcome) {
      PermissionCycleOutcome.switched => LivePermissionOutcome.switched,
      PermissionCycleOutcome.notOffered => LivePermissionOutcome.notOffered,
      PermissionCycleOutcome.noAnswer => LivePermissionOutcome.noAnswer,
      PermissionCycleOutcome.unreachable => LivePermissionOutcome.nextLaunch,
    };
  }
}
