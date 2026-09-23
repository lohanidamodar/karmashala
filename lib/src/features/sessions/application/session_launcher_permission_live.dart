part of 'session_launcher.dart';

/// What became of moving a running session's permission mode.
enum LivePermissionOutcome {
  /// The agent's screen now shows the mode that was asked for.
  switched,

  /// The agent's own permission picker is open in the pane; the person chooses.
  openedPicker,

  /// The agent is mid-turn; the change is sent when it is next idle.
  held,

  /// The cycle came round without showing that mode: this session does not
  /// offer it, so it applies from the next launch. Left as it was found.
  notOffered,

  /// No running session, or no way to move one; the next launch applies it.
  nextLaunch,
}

/// How long the agent is given to redraw its mode after one step of the cycle.
const Duration kPermissionCycleSettle = Duration(milliseconds: 350);

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
    final idle =
        _ref.read(sessionActivityLookupProvider)(sessionId) ==
        AgentActivityStatus.idle;
    final live = support.live;
    if (live != null) {
      final target = support
          .normalise(effective.selection)
          .valueFor(live.axisId);
      if (target == null || !live.reachable.contains(target)) {
        return LivePermissionOutcome.nextLaunch;
      }
      if (!idle) {
        // A key pressed mid-turn can land in a prompt the agent has open.
        if (!turnWillEnd(sessionId)) return LivePermissionOutcome.nextLaunch;
        _ref.read(pendingLiveSwitchesProvider).holdPermission(sessionId);
        return LivePermissionOutcome.held;
      }
      return _cycleTo(sessionId, live, target, settle);
    }
    if (support.pickerCommand.isNotEmpty &&
        idle &&
        sendTo(sessionId, support.pickerCommand)) {
      return LivePermissionOutcome.openedPicker;
    }
    return LivePermissionOutcome.nextLaunch;
  }

  /// Steps the cycle until the screen shows [target], reading it back after
  /// every step. Coming round to where it started means the mode is not on
  /// offer, and the session is left in the mode it was found in.
  Future<LivePermissionOutcome> _cycleTo(
    String sessionId,
    AgentPermissionLiveCycle live,
    String target,
    Duration settle,
  ) async {
    String? now() {
      final terminal = _liveTerminalFor(sessionId);
      return terminal == null ? null : live.read(terminalTailLines(terminal));
    }

    final start = now();
    if (start == null) return LivePermissionOutcome.nextLaunch;
    if (start == target) return LivePermissionOutcome.switched;
    for (var step = 0; step <= live.order.length; step++) {
      if (!pressKeys(sessionId, live.key)) {
        return LivePermissionOutcome.nextLaunch;
      }
      await Future<void>.delayed(settle);
      final seen = now();
      if (seen == null) return LivePermissionOutcome.nextLaunch;
      if (seen == target) {
        _log.info(
          'Moved $sessionId to $target in place in ${step + 1} step(s)',
        );
        return LivePermissionOutcome.switched;
      }
      if (seen == start) return LivePermissionOutcome.notOffered;
    }
    return LivePermissionOutcome.notOffered;
  }
}
