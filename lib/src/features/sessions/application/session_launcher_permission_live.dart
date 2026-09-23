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

/// The longest the agent is given to redraw its mode after one step. A bound,
/// not a sleep: the screen is read again as soon as it shows a different mode.
const Duration kPermissionCycleSettle = Duration(seconds: 2);

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

    /// The mode once the screen shows one other than [before], or [before]
    /// again when [settle] passes without a redraw.
    Future<String?> changedFrom(String before) async {
      const poll = Duration(milliseconds: 40);
      // Counted in waits taken rather than read off a stopwatch, so a test's
      // fake clock bounds it exactly as the real one does.
      for (var waited = Duration.zero; ; waited += poll) {
        final seen = now();
        if (seen == null || seen != before || waited >= settle) return seen;
        await Future<void>.delayed(poll);
      }
    }

    final start = now();
    if (start == null) return LivePermissionOutcome.nextLaunch;
    if (start == target) return LivePermissionOutcome.switched;
    var at = start;
    for (var step = 0; step <= live.order.length; step++) {
      if (!pressKeys(sessionId, live.key)) {
        return LivePermissionOutcome.nextLaunch;
      }
      final seen = await changedFrom(at);
      if (seen == null) return LivePermissionOutcome.nextLaunch;
      // An unchanged screen is a step not yet drawn, not a lap completed.
      if (seen == at) return LivePermissionOutcome.noAnswer;
      if (seen == target) return LivePermissionOutcome.switched;
      if (seen == start) return LivePermissionOutcome.notOffered;
      at = seen;
    }
    return LivePermissionOutcome.notOffered;
  }
}
