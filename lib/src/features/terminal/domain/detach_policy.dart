/// Whether closing a pane keeps its process alive.
///
/// Karmashala detaches rather than kills, which is right for a running agent, a
/// build, a dev server or an ssh session, and wrong for a shell nobody typed
/// in: that left a PowerShell running with no tab, a spool, and a row in the
/// layout restored on the next launch. The rule, in one place and pure so it
/// can be tested without a process: keep what someone would miss, release what
/// nobody would.
library;

/// Non-blank lines of **its own** an un-instrumented shell may have before its
/// buffer counts as history worth keeping.
///
/// The common path, so it errs towards *keeping*: being wrong that way leaves a
/// session running, the other way ends one somebody wanted. Six was derived
/// from single-line prompts and a multi-line one breaks that arithmetic — a
/// starship zsh redraws three rows per command — so the six is counted on top
/// of the greeting the pane measured for itself.
const int kIdleShellHistoryLines = 6;

/// Whether closing this pane should detach it rather than end it.
///
/// An agent session and a running command are always kept; an instrumented
/// shell at an idle prompt is released, because the shell said it is running
/// nothing; an un-instrumented one is kept only if it has real history, the
/// buffer being the only evidence there is. [greetingLines] is what "beyond its
/// banner" is measured against, and null counts from zero — the safe way.
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

/// Whether a pane that has just exited should close itself.
///
/// Typing `exit` is a request to be done with that shell, and a pane is a
/// working surface rather than a record of one. Two exceptions: an **agent
/// session** stays, because its scrollback is the point and ending one may have
/// cost real money, and a **failure** stays, because a non-zero pane holds the
/// error somebody opened the terminal to read. An exit status we never learned
/// counts as "not clean". Not behind a setting, because the exit code already
/// separates the dangerous half out.
bool shouldCollapseOnExit({
  required bool isAgentSession,
  required int? exitCode,
}) => !isAgentSession && exitCode == 0;
