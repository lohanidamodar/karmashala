import 'package:riverpod/riverpod.dart';

import '../../terminal/application/terminal_sessions_controller.dart';
import '../../terminal/domain/pane_liveness.dart';
import '../data/session_dao.dart';
import '../domain/session_status.dart';
import 'session_launch_refusal.dart';
import 'session_providers.dart';
import 'session_signals.dart';

/// **Takes a row out of `running` when nothing we can see is running it.**
///
/// Nothing else ever did: the writers only ever move a pane-hosted session
/// *into* `running`, so a conversation that ended three days ago still drew a
/// play glyph in the Explorer. It was never only a wrong icon — four things
/// filter on `== running`, and a stale row keeps
/// `SessionTitleSyncService.wantsStoreSweep` true, buying a CLI-store scan on
/// every slow slot for the rest of the app's run.
///
/// The rule: a row that claims to be live and does not name a **live pane of
/// ours** is not running — an observation, not an inference. Applied at exactly
/// two moments and never polled: on launch, when there are no live panes at all
/// (restore never brings an agent pane back with a process in it), and when a
/// pane stops being live, read off the terminal's own liveness map because
/// `paneExitProvider` covers only the agent exiting by itself.
///
/// It never writes `completed`, `failed` or `cancelled`: losing sight of a
/// session says nothing about how it ended, and [SessionStatus.unknown] is the
/// whole answer. Nor does it touch a row that has already reached a terminal
/// status — a user's `cancelled` must not be overwritten with a vaguer word.
class SessionLivenessReconciler {
  SessionLivenessReconciler({required this.sessionDao, this.onChanged});

  final SessionDao sessionDao;

  /// Called with each row this moved, so the workspace can redraw. Null in the
  /// launch sweep, which runs before any of it exists.
  final void Function(String sessionId)? onChanged;

  /// Rows moved out of a live claim. Diagnostics, and what the tests count.
  int reconciled = 0;

  /// Sweeps **every** row that claims to be live against [livePaneIds] — the
  /// launch pass. Costs one indexed read of a set that is normally empty.
  int sweep(Set<String> livePaneIds) {
    var moved = 0;
    for (final session in sessionDao.getClaimingLive()) {
      final paneId = session.paneId;
      if (paneId != null && livePaneIds.contains(paneId)) continue;
      _lose(session.id);
      moved++;
    }
    return moved;
  }

  /// Sweeps only the rows hosted by [paneIds] — panes that have just stopped.
  /// Keyed on the panes rather than on the session table, so a process exiting
  /// costs one indexed lookup and not a scan; a row that has since moved to
  /// another pane is not returned by that lookup and so is not touched.
  int panesStopped(Iterable<String> paneIds) {
    var moved = 0;
    for (final session in sessionDao.getByPaneIds(paneIds)) {
      if (!session.status.claimsLive) continue;
      _lose(session.id);
      moved++;
    }
    return moved;
  }

  void _lose(String sessionId) {
    sessionDao.updateStatus(sessionId, SessionStatus.unknown);
    reconciled++;
    onChanged?.call(sessionId);
  }
}

/// The launch pass: every row that survived a restart still claiming to be live
/// is one we have lost sight of. Called from `main` before any pane exists,
/// which is what makes the empty set below a fact rather than an assumption.
int markSessionsLostOnLaunch(SessionDao dao) =>
    SessionLivenessReconciler(sessionDao: dao).sweep(const {});

/// Pane ids that were running in [previous] and are not running in [next]. A
/// pure function over the two published maps, so the listener below touches the
/// database only when something actually stopped. A pane the map has dropped
/// entirely counts — closing a tab removes its entry rather than marking it.
Set<String> panesThatStoppedRunning(
  Map<String, PaneLiveness>? previous,
  Map<String, PaneLiveness> next,
) {
  if (previous == null || previous.isEmpty) return const {};
  final stopped = <String>{};
  for (final entry in previous.entries) {
    if (!entry.value.isLive) continue;
    if (next[entry.key]?.isLive ?? false) continue;
    stopped.add(entry.key);
  }
  return stopped;
}

/// Watches the terminal's published liveness and reconciles what it says.
///
/// **It has to be watched, not read.** Riverpod 3 pauses a provider's own
/// subscriptions while nothing listens to that provider, so a reconciler nobody
/// watches would see no pane ever stop — silently. It listens to the whole
/// `TerminalSessionsState` rather than a per-pane family because it is the one
/// subscriber that has to hear about a pane it does not already know.
final sessionLivenessReconcilerProvider = Provider<void>((ref) {
  final reconciler = SessionLivenessReconciler(
    sessionDao: ref.read(sessionDaoProvider),
    onChanged: (sessionId) => ref
        .read(sessionsRevisionProvider.notifier)
        .changed(SessionChange.statusChanged(sessionId)),
  );
  ref.listen(terminalSessionsControllerProvider, (previous, next) {
    final stopped = panesThatStoppedRunning(previous?.liveness, next.liveness);
    if (stopped.isEmpty) return;
    reconciler.panesStopped(stopped);
    // The same edge, and the only one on which a refusal is readable: the CLI
    // has printed it and exited. See [reportRefusedLaunches].
    reportRefusedLaunches(ref, stopped);
  });
});
