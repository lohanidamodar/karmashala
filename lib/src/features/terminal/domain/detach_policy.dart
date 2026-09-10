/// Whether closing a pane keeps its process alive: keep what someone would
/// miss, release what nobody would. Pure, so it is testable without a process.
library;

/// Non-blank lines of **its own** a shell may print before its buffer counts as
/// history — on top of its greeting, since a prompt can redraw three rows.
const int kIdleShellHistoryLines = 6;

/// Whether closing this pane should detach it rather than end it. An agent
/// session or a running command is always kept; a shell only with real history.
bool shouldDetachOnClose({
  required bool isLive,
  required bool isAgentSession,
  required bool? commandRunning,
  required int nonBlankLines,
  required int? greetingLines,
}) {
  if (!isLive) return false;
  if (isAgentSession) return true;
  if (commandRunning != null) return commandRunning;
  return nonBlankLines > (greetingLines ?? 0) + kIdleShellHistoryLines;
}

/// Whether a pane that has just exited should close itself. An agent session
/// stays, and so does a failure: a non-zero pane holds an error to be read.
bool shouldCollapseOnExit({
  required bool isAgentSession,
  required int? exitCode,
}) => !isAgentSession && exitCode == 0;
