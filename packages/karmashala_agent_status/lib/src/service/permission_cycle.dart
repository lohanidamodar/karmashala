import 'package:agent_cli/descriptors.dart';

/// The longest an agent is given to redraw its mode after one step. A bound,
/// not a sleep: the screen is read again as soon as it shows a different mode.
const Duration kPermissionCycleSettle = Duration(seconds: 2);

/// What stepping an agent's permission cycle came to.
enum PermissionCycleOutcome {
  /// The screen now shows the mode asked for.
  switched,

  /// The cycle came round without showing that mode: this session does not
  /// offer it. Left in the mode it was found in.
  notOffered,

  /// The agent never redrew its mode after a step, so nothing more was pressed.
  noAnswer,

  /// No screen to read, or no way to press the key.
  unreachable,
}

/// Steps [live]'s cycle key until the screen shows [target], reading it back
/// after every step — the one way the app's panes and the session host's
/// PTYs move a running session's mode. [read] answers the mode on screen now
/// (null when there is no screen); [press] presses [live]'s key once (false
/// when it could not). Coming round to where it started means the mode is not
/// on offer, and the session is left in the mode it was found in.
Future<PermissionCycleOutcome> cyclePermissionTo(
  AgentPermissionLiveCycle live,
  String target, {
  required String? Function() read,
  required bool Function() press,
  Duration settle = kPermissionCycleSettle,
}) async {
  /// The mode once the screen shows one other than [before], or [before]
  /// again when [settle] passes without a redraw.
  Future<String?> changedFrom(String before) async {
    const poll = Duration(milliseconds: 40);
    // Counted in waits taken rather than read off a stopwatch, so a test's
    // fake clock bounds it exactly as the real one does.
    for (var waited = Duration.zero; ; waited += poll) {
      final seen = read();
      if (seen == null || seen != before || waited >= settle) return seen;
      await Future<void>.delayed(poll);
    }
  }

  final start = read();
  if (start == null) return PermissionCycleOutcome.unreachable;
  if (start == target) return PermissionCycleOutcome.switched;
  var at = start;
  for (var step = 0; step <= live.order.length; step++) {
    if (!press()) return PermissionCycleOutcome.unreachable;
    final seen = await changedFrom(at);
    if (seen == null) return PermissionCycleOutcome.unreachable;
    // An unchanged screen is a step not yet drawn, not a lap completed.
    if (seen == at) return PermissionCycleOutcome.noAnswer;
    if (seen == target) return PermissionCycleOutcome.switched;
    if (seen == start) return PermissionCycleOutcome.notOffered;
    at = seen;
  }
  return PermissionCycleOutcome.notOffered;
}
