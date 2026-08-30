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
  Duration gracePeriod = kProcessGracePeriod,
  bool? supportsGracefulSignal,
}) async {
  final graceful = supportsGracefulSignal ?? platformSupportsGracefulSignal;

  // Swallow the exit future's errors up front, so nothing escapes later.
  final exited = exitCode.then<void>((_) {}, onError: (_) {});

  if (!graceful) {
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
