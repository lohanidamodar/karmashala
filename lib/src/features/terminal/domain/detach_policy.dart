/// Whether closing a pane keeps its process alive.
///
/// Chitragupta detaches rather than kills, and that is the right default for
/// the thing it is for: closing the tab of a running agent, a build, a dev
/// server or an ssh session must not end it. But it was applied to *every* live
/// pane, so opening a shell, typing nothing, and closing the tab left a
/// PowerShell running with no tab — and, since the tiering work, a cold pane
/// with a spool and a row in the workspace, restored on the next launch.
/// Multiplied by a working day that is a background session list nobody asked
/// for and a slower restore every morning.
///
/// The rule, in one place and pure so it can be tested without a process: keep
/// what someone would miss, release what nobody would.
///
/// Pure Dart on purpose — no xterm, no Flutter — so the whole decision is unit
/// testable. The caller supplies the four observations.
library;

/// Non-blank lines an un-instrumented shell may have before its buffer counts
/// as history worth keeping.
///
/// This is the fallback, and — because shell integration is **off by default**
/// — it is also the common path, so it is deliberately conservative. A fresh
/// prompt is a banner and a prompt line: PowerShell prints two or three lines
/// and a prompt, `cmd.exe` two, `bash` usually one. Six covers those with room
/// to spare and errs towards *keeping*, which is the safe direction: being
/// wrong that way leaves a session running, and being wrong the other way ends
/// one somebody wanted.
///
/// A shell with a login MOTD long enough to clear six lines is always kept,
/// which is the same safe direction. Turning shell integration on replaces this
/// guess with the shell's own answer.
const int kIdleShellHistoryLines = 6;

/// Whether closing this pane should detach it rather than end it.
///
/// * **Not live** — nothing to keep; the process is already gone.
/// * **An agent session** — always kept. It is the unit of work the app is
///   about, it may be mid-turn, and its transcript is the point.
/// * **A command executing** — always kept. OSC 133 says so directly, and a
///   build or a dev server that dies because a tab was closed is exactly the
///   failure detaching exists to prevent.
/// * **An instrumented shell at an idle prompt** — released. The shell told us
///   it is running nothing; there is no guessing to do.
/// * **An un-instrumented shell** — kept only if it has real history, because
///   without OSC 133 the buffer is the only evidence there is. A shell that has
///   printed nothing beyond its banner has nothing anyone would come back for.
bool shouldDetachOnClose({
  required bool isLive,
  required bool isAgentSession,
  required bool? commandRunning,
  required int nonBlankLines,
}) {
  if (!isLive) return false;
  if (isAgentSession) return true;
  if (commandRunning != null) return commandRunning;
  return nonBlankLines > kIdleShellHistoryLines;
}
