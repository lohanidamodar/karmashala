/// Tearing down the process behind a terminal pane without destroying its work.
library;

import 'dart:async';
import 'dart:io';

/// How long a process gets to exit cleanly before it is force-killed.
///
/// Long enough for a shell to run its exit hooks and for a child to flush, short
/// enough that closing a tab still feels immediate.
const kProcessGracePeriod = Duration(seconds: 2);

/// How long the tree kill may be waited for before a pane's teardown stops
/// holding the isolate for it.
///
/// The same number as `AppLifecycle`'s terminal-processes slice, deliberately:
/// the reap runs *inside* that step, so a kill still being waited on after the
/// step was abandoned is work outliving the shutdown that owns it — and on
/// 2026-09-09 that is what a quit which never finished looked like. The wait is
/// what is abandoned, never the kill: `taskkill` goes on doing exactly what it
/// was asked.
const kProcessTreeKillBound = Duration(milliseconds: 2500);

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
///
/// **It is the whole cost of quitting**, and that was measured rather than
/// assumed. On 2026-09-09 the app soak's terminal step was abandoned at its cap
/// on nearly every cycle with a single pane to reap; a probe around this call
/// put 1284-1934 ms of that on `taskkill.exe`, and releasing the
/// pseudoconsole after it — the suspect — on 1-22 ms. `taskkill.exe /PID
/// 999999` on the same machine, killing nothing at all, took 812-983 ms. So
/// this is one Windows binary starting up, and there is nothing here to make
/// faster short of a job object at launch (see `flutter_pty`).
///
/// The wait for it is bounded by [shutdownProcess], which is what stops a
/// `taskkill` that does not come back from becoming a quit that never
/// finishes.
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
  Duration treeKillBound = kProcessTreeKillBound,
}) async {
  final graceful = supportsGracefulSignal ?? platformSupportsGracefulSignal;

  // Swallow the exit future's errors up front, so nothing escapes later.
  final exited = exitCode.then<void>((_) {}, onError: (_) {});

  if (!graceful) {
    // [pid] is null once the process is known to have exited: the OS recycles
    // pids, and killing a tree by a stale number could hit a stranger.
    if (pid != null) {
      // **Waited on the pane's process going, not on `taskkill.exe` coming
      // back.** Measured through this very call on 2026-09-09:
      // `Process.run('taskkill.exe', ['/PID', …, '/T', '/F'])` costs
      // 1039-1778 ms, `taskkill /?` — the binary starting up and doing nothing
      // — 196-214 ms, and `cmd /c exit` through the same API 134-160 ms. So
      // nearly a second of it is `taskkill` walking the process table, and the
      // kill lands near the end of that. Whichever of the two arrives first is
      // the answer, because the pane's own exit *is* the tree kill having
      // worked.
      final tree = (killTree ?? killWindowsProcessTree)(pid)
          // Never a failed teardown, and never an unhandled error after
          // [exited] has already won the race below.
          .catchError((Object _) {});
      try {
        await Future.any([exited, tree]).timeout(treeKillBound);
      } catch (_) {
        // Still going when the bound expired. The spawn is left running on
        // purpose — Windows does not end a child when its parent does, so the
        // tree is reaped whether or not this process is still here to see it —
        // and the direct kill below is the fallback.
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
