/// Tearing down the process behind a terminal pane without destroying its work.
library;

import 'dart:async';
import 'dart:io';

/// How long a process gets to exit cleanly before it is force-killed.
///
/// Long enough for a shell to run its exit hooks and for a child to flush, short
/// enough that closing a tab still feels immediate.
const kProcessGracePeriod = Duration(seconds: 2);

/// Whether this platform has a signal that asks a process to exit rather than
/// destroying it.
///
/// Windows does not: `Process.killPid` only supports SIGTERM and SIGKILL, and
/// both are `TerminateProcess`. Pretending otherwise would add the whole grace
/// period to every tab close and gain nothing.
bool get platformSupportsGracefulSignal => !Platform.isWindows;

/// Ends the process tree rooted at [pid]. Injected so tests never spawn one.
typedef ProcessTreeKiller = Future<void> Function(int pid);

/// Force-kills [pid] **and its descendants**.
///
/// Terminating a Windows process orphans its children rather than taking them
/// with it, so a bare kill leaves behind exactly what the user asked to be rid
/// of — the dev server or build running inside the shell. Two things make this
/// necessary rather than belt-and-braces:
///
/// * `flutter_pty` 0.4.2 builds its command line as `<exe> <argv…>` where argv
///   already starts with the executable, so `powershell.exe` is launched as
///   `powershell.exe powershell.exe`. PowerShell's default parameter is
///   `-Command`, so that spawns a **nested** shell — and the pid the PTY hands
///   back is the outer wrapper, not the shell the user is typing into. Killing
///   the pid alone therefore left the real session running.
/// * Even without that, `npm run dev` in a pane is a child of the shell.
///
/// Never throws: the tree may already be gone, and tearing down a pane must not
/// fail.
Future<void> killWindowsProcessTree(int pid) async {
  try {
    await Process.run('taskkill.exe', ['/PID', '$pid', '/T', '/F']);
  } catch (_) {
    // taskkill missing or refused; the direct kill below is the fallback.
  }
}

/// Shuts a process down politely, then forcibly if it does not co-operate.
///
/// A bare kill is wrong for anything long-running — a build, a dev server, an
/// ssh session, a database client mid-write — because the process never gets to
/// flush, checkpoint or run its exit handlers. This asks first and waits a
/// bounded [gracePeriod] before escalating.
///
/// Never throws: the process may already be gone, and tearing down a pane must
/// not fail.
Future<void> shutdownProcess({
  required bool Function(ProcessSignal) kill,
  required Future<int> exitCode,
  int? pid,
  Duration gracePeriod = kProcessGracePeriod,
  bool? supportsGracefulSignal,
  ProcessTreeKiller? killTree,
}) async {
  final graceful = supportsGracefulSignal ?? platformSupportsGracefulSignal;

  // Swallow the exit future's errors up front, so nothing escapes later.
  final exited = exitCode.then<void>((_) {}, onError: (_) {});

  if (!graceful) {
    // [pid] is null once the process is known to have exited: the OS recycles
    // pids, and killing a tree by a stale number could hit a stranger.
    if (pid != null) {
      try {
        await (killTree ?? killWindowsProcessTree)(pid);
      } catch (_) {
        // The direct kill below is the fallback; never fail a teardown.
      }
    }
    _tryKill(kill, ProcessSignal.sigterm);
    return;
  }

  // SIGHUP is what a real terminal sends when its window closes, so shells and
  // well-behaved children already know what it means.
  _tryKill(kill, ProcessSignal.sighup);

  try {
    await exited.timeout(gracePeriod);
    return;
  } on TimeoutException {
    // Ignored on purpose: escalate below.
  } catch (_) {
    return;
  }

  _tryKill(kill, ProcessSignal.sigkill);
}

void _tryKill(bool Function(ProcessSignal) kill, ProcessSignal signal) {
  try {
    kill(signal);
  } catch (_) {
    // Already gone, or the platform refused the signal. Nothing to do.
  }
}
