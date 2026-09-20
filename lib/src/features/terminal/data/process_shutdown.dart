/// Tearing down the process behind a terminal pane without destroying its work.
library;

import 'dart:async';
import 'dart:io';

/// How long a process gets to exit cleanly before it is force-killed. Long
/// enough for a shell to run its exit hooks and for a child to flush, short
/// enough that closing a tab still feels immediate.
const kProcessGracePeriod = Duration(seconds: 2);

/// How long the tree kill may be waited for. The same number as `AppLifecycle`'s
/// terminal slice: the wait is abandoned when that step is, never the kill.
const kProcessTreeKillBound = Duration(milliseconds: 2500);

/// Whether this platform has a signal that asks a process to exit rather than
/// destroying it. Windows does not — `Process.killPid` supports only SIGTERM
/// and SIGKILL, and both are `TerminateProcess`.
bool get platformSupportsGracefulSignal => !Platform.isWindows;

/// Ends the process tree rooted at [pid]. Injected so tests never spawn one.
typedef ProcessTreeKiller = Future<void> Function(int pid);

/// What was **observed** by the time [shutdownProcess] stopped waiting. Four
/// values, because a kill returning is not the pane's process being seen to go.
enum ProcessShutdownOutcome {
  /// The process was already known to have gone before teardown began, so no
  /// tree kill was attempted.
  alreadyGone,

  /// The process exited while this was waiting. On Windows that **is** the tree
  /// kill having worked, which is why it is the outcome worth waiting for.
  exited,

  /// The tree kill returned first and the process was not seen to go. Usually
  /// it has — `taskkill.exe` spends most of its second walking the process
  /// table and the kill lands near the end — but usually is not observed.
  killReturned,

  /// Neither arrived within the bound. The kill is still running -- the wait is
  /// what was abandoned, never the kill.
  notObserved;

  /// Whether the process behind the pane was actually seen to be gone. False
  /// for [killReturned] on purpose: see its own note.
  bool get processGone =>
      this == ProcessShutdownOutcome.exited ||
      this == ProcessShutdownOutcome.alreadyGone;
}

/// Force-kills [pid] **and its descendants** — a Windows process orphans its
/// children. Never throws, and it is the whole cost of quitting (~1 s).
Future<void> killWindowsProcessTree(int pid) async {
  try {
    await Process.run('taskkill.exe', ['/PID', '$pid', '/T', '/F']);
  } catch (_) {
    // taskkill missing or refused; the direct kill below is the fallback.
  }
}

/// Shuts a process down politely, then forcibly. A bare kill never lets a build
/// or a database client flush. Never throws: tearing down a pane must not fail.
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

  // Swallow the exit future's errors up front. The flag is what lets the
  // outcome say *which* of the two ended the wait, since `Future.any` does not.
  var sawExit = false;
  final exited = exitCode.then<void>((_) => sawExit = true, onError: (_) {});

  if (!graceful) {
    // [pid] is null once the process is known to have exited: the OS recycles
    // pids, and killing a tree by a stale number could hit a stranger.
    if (pid == null) {
      _tryKill(kill, ProcessSignal.sigterm);
      return ProcessShutdownOutcome.alreadyGone;
    }

    // Waited on the pane's exit, not on `taskkill.exe` returning: the kill
    // lands near the end of its second, and the exit *is* the evidence.
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
      // purpose — Windows does not end a child when its parent does — and the
      // direct kill below is the fallback.
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
/// its pseudoconsole. A value rather than a log string because "console
/// released" is only readable next to whether the tree had actually gone.
class PaneCloseReport {
  const PaneCloseReport({required this.outcome, required this.consoleReleased});

  /// What was observed of the pane's own process tree.
  final ProcessShutdownOutcome outcome;

  /// Whether the pseudoconsole was released, or left to the OS — false exactly
  /// when the shutdown about to end the process asked this pane to keep it.
  final bool consoleReleased;

  /// The pane's log line, in the words the incident is remembered by.
  String get summary {
    final tree = switch (outcome) {
      ProcessShutdownOutcome.alreadyGone => 'tree already gone',
      ProcessShutdownOutcome.exited => 'tree gone',
      ProcessShutdownOutcome.killReturned =>
        'kill returned, tree not seen gone',
      ProcessShutdownOutcome.notObserved =>
        'tree not seen gone within the bound',
    };
    return consoleReleased
        ? 'console released, $tree'
        : 'console left to the OS (quit), $tree';
  }
}

/// Ends the process behind a pane, then releases its pseudoconsole. Nothing
/// here waits from the platform thread: that hung the main thread on WSL.
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
    // console still has to be let go of.
  }
  if (keepPseudoConsole()) {
    return PaneCloseReport(outcome: outcome, consoleReleased: false);
  }
  releasePseudoConsole();
  return PaneCloseReport(outcome: outcome, consoleReleased: true);
}
