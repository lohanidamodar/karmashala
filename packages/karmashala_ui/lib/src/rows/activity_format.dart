/// The wording and cadence a running-tool strip is drawn to.
library;

/// How often the elapsed times are redrawn. A `setState` on this widget alone,
/// armed only while there is something to count, so a quiet session pays none.
const Duration kActivityTickInterval = Duration(seconds: 1);

/// The collapsed label for several calls at once, kept honest about how many of
/// them are other agents.
String describeRunningMix(int total, int subagents) {
  final tools = total - subagents;
  if (subagents == 0) return '$total tools running';
  if (tools == 0) return '$subagents ${_plural('subagent', subagents)} running';
  return '$tools ${_plural('tool', tools)} and $subagents '
      '${_plural('subagent', subagents)} running';
}

String _plural(String word, int count) => count == 1 ? word : '${word}s';

/// How long a call has been out. **It reaches hours, and it has to**: the
/// longest in the owner's store is a `Bash` call at 514.8 minutes.
String formatElapsed(Duration elapsed) {
  final seconds = elapsed.inSeconds;
  if (seconds < 60) return '${seconds}s';
  if (elapsed.inHours < 1) return '${elapsed.inMinutes}m ${seconds % 60}s';
  return '${elapsed.inHours}h ${elapsed.inMinutes % 60}m';
}
