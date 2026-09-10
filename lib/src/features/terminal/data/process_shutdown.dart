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

/// What was **observed** by the time [shutdownProcess] stopped waiting.
///
/// Four values rather than a bool because they are four different findings and
/// the log line has to be able to tell them apart. None of them claims more
/// than was seen: a tree kill that came back is not the same evidence as the
/// pane's own process going, and a bound that expired is not evidence of
/// anything at all.
enum ProcessShutdownOutcome {
  /// The process was already known to have gone before teardown began, so no
  /// tree kill was attempted.
  alreadyGone,

  /// The process exited while this was waiting. On Windows that **is** the tree
  /// kill having worked, which is why it is the outcome worth waiting for.
  exited,

  /// The tree kill returned first and the process was not seen to go. Usually
  /// it has: `taskkill.exe` spends most of its second walking the process table
  /// and the kill lands near the end, so the exit is often just behind. Usually
  /// is not the same as observed.
  killReturned,

  /// Neither arrived within the bound. The kill is still running -- the wait is
  /// what was abandoned, never the kill.
  notObserved;

  /// Whether the process behind the pane was actually seen to be gone.
  ///
  /// False for [killReturned] on purpose: see its own note.
  bool get processGone =>
      this == ProcessShutdownOutcome.exited ||
      this == ProcessShutdownOutcome.alreadyGone;
}

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
Future<ProcessShutdownOutcome> shutdownProcess({
  required bool Function(ProcessSignal) kill,
  required Future<int> exitCode,
  int? pid,
  Duration gracePeriod = kProcessGracePeriod,
  bool? supportsGracefulSignal,
  ProcessTreeKiller? killTree,
  Duration treeKillBound = kProcessTreeKillBound,
}) async {
  final graceful = supportsGracefulSignal ?? platformSupportsGracefulSignal;

  // Swallow the exit future's errors up front, so nothing escapes later. The
  // flag is what lets the outcome say *which* of the two ended the wait, since
  // `Future.any` does not.
  var sawExit = false;
  final exited = exitCode.then<void>((_) => sawExit = true, onError: (_) {});

  if (!graceful) {
    // [pid] is null once the process is known to have exited: the OS recycles
    // pids, and killing a tree by a stale number could hit a stranger.
    if (pid == null) {
      _tryKill(kill, ProcessSignal.sigterm);
      return ProcessShutdownOutcome.alreadyGone;
    }

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
    var outcome = ProcessShutdownOutcome.notObserved;
    try {
      await Future.any([exited, tree]).timeout(treeKillBound);
      outcome = sawExit
          ? ProcessShutdownOutcome.exited
          : ProcessShutdownOutcome.killReturned;
    } catch (_) {
      // Still going when the bound expired. The spawn is left running on
      // purpose — Windows does not end a child when its parent does, so the
      // tree is reaped whether or not this process is still here to see it —
      // and the direct kill below is the fallback.
    }
    _tryKill(kill, ProcessSignal.sigterm);
    return outcome;
  }

  // SIGHUP is what a real terminal sends when its window closes, so shells and
  // well-behaved children already know what it means.
  _tryKill(kill, ProcessSignal.sighup);

  try {
    await exited.timeout(gracePeriod);
    return ProcessShutdownOutcome.exited;
  } on TimeoutException {
    // Ignored on purpose: escalate below.
  } catch (_) {
    return ProcessShutdownOutcome.notObserved;
  }

  _tryKill(kill, ProcessSignal.sigkill);
  return ProcessShutdownOutcome.notObserved;
}

void _tryKill(bool Function(ProcessSignal) kill, ProcessSignal signal) {
  try {
    kill(signal);
  } catch (_) {
    // Already gone, or the platform refused the signal. Nothing to do.
  }
}

/// What one pane's close did: what became of its process, and what became of
/// its pseudoconsole.
///
/// A value rather than a log string because the two facts belong together —
/// "console released" is only readable next to whether the tree it was waiting
/// on had actually gone — and because a test can assert on a value.
class PaneCloseReport {
  const PaneCloseReport({
    required this.outcome,
    required this.consoleReleased,
  });

  /// What was observed of the pane's own process tree.
  final ProcessShutdownOutcome outcome;

  /// Whether the pseudoconsole was released, or left to the OS.
  ///
  /// False exactly when the shutdown that is about to end the process asked
  /// this pane to keep it — see `PseudoConsoleOwner`. Never a failure.
  final bool consoleReleased;

  /// The pane's log line, in the words the incident is remembered by.
  String get summary {
    final tree = switch (outcome) {
      ProcessShutdownOutcome.alreadyGone => 'tree already gone',
      ProcessShutdownOutcome.exited => 'tree gone',
      ProcessShutdownOutcome.killReturned => 'kill returned, tree not seen gone',
      ProcessShutdownOutcome.notObserved => 'tree not seen gone within the bound',
    };
    return consoleReleased
        ? 'console released, $tree'
        : 'console left to the OS (quit), $tree';
  }
}

/// Ends the process behind a pane and then lets go of its pseudoconsole.
///
/// The pane-close counterpart of the quit sequence, and deliberately the same
/// shape: kill the tree, wait for the pane's own exit or the kill's return
/// whichever comes first, bounded by [treeKillBound] — which is
/// `AppLifecycle`'s terminal-processes slice — and then release the console
/// and stop.
///
/// **Nothing here waits on a process from the platform thread.** The wait above
/// is a Dart future, and the release is `Pty.destroy`, which since 2026-09-10
/// hands `ClosePseudoConsole` to a detached native thread and returns
/// immediately. Before that it was a synchronous unbounded call on whichever
/// thread closed the pane: a minidump of a hung 1.20.1 caught the app's main
/// thread inside it with four live console hosts, and closing a WSL pane whose
/// Linux side kept running was all it took.
///
/// [keepPseudoConsole] is read **after** the reap rather than captured before
/// it, because the quit can arrive while a pane close is still in flight — and
/// a release reached during a shutdown is the one case that must not happen.
///
/// Never throws: tearing down a pane must not fail.
Future<PaneCloseReport> closePaneProcess({
  required bool Function(ProcessSignal) kill,
  required Future<int> exitCode,
  required bool Function() keepPseudoConsole,
  required void Function() releasePseudoConsole,
  int? pid,
  Duration gracePeriod = kProcessGracePeriod,
  bool? supportsGracefulSignal,
  ProcessTreeKiller? killTree,
  Duration treeKillBound = kProcessTreeKillBound,
}) async {
  var outcome = ProcessShutdownOutcome.notObserved;
  try {
    outcome = await shutdownProcess(
      kill: kill,
      exitCode: exitCode,
      pid: pid,
      gracePeriod: gracePeriod,
      supportsGracefulSignal: supportsGracefulSignal,
      killTree: killTree,
      treeKillBound: treeKillBound,
    );
  } catch (_) {
    // `shutdownProcess` is documented never to throw. If it ever does, the
    // console still has to be let go of — the descriptor and reader thread
    // behind it outlive the pane either way.
  }
  if (keepPseudoConsole()) {
    return PaneCloseReport(outcome: outcome, consoleReleased: false);
  }
  releasePseudoConsole();
  return PaneCloseReport(outcome: outcome, consoleReleased: true);
}
