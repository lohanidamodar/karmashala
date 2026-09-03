import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../terminal/application/terminal_sessions_controller.dart';
import '../../terminal/domain/pane_liveness.dart';
import '../data/session_dao.dart';
import '../domain/session_status.dart';
import 'session_providers.dart';
import 'session_signals.dart';

/// **Takes a row out of `running` when nothing we can see is running it.**
///
/// Until this existed nothing ever did. `SessionLauncher` and
/// `SessionAdoptionService` write [SessionStatus.running]; `SessionEngine`
/// writes the terminal statuses and no in-app session uses it any more (every
/// one of them runs in a PTY); `SessionEngine.dispose` deliberately leaves a
/// run `running` on the way out. So the only transition a pane-hosted session
/// ever made was *into* `running`, and a conversation that ended three days ago
/// still drew a play glyph in the Explorer — which is exactly the report this
/// was written for.
///
/// It was never only a wrong icon. Four things filter on `== running` and each
/// of them was paying for the zombies: `SessionCheckpointRecorder` and
/// `SessionEndingObserver` open one status subscription per running row, and
/// `SessionTitleSyncService` keeps `wantsStoreSweep` true for as long as one
/// running row carries a CLI-given name — its own comment says "permanently
/// waiting here" — so a stale row bought a CLI-store scan on every slow slot
/// for the rest of the app's run.
///
/// ## The rule, and why it is the only one used
///
/// A row that claims to be live and does not name a **live pane of ours** is
/// not running. That is an observation, not an inference: the pane is our own
/// process and its liveness is a fact we hold in memory.
///
/// It is applied at exactly two moments, and there is no poll:
///
/// * **On launch**, from `main`, with no live panes at all — because at that
///   point there are none. Restore never brings an agent pane back with a
///   process in it (`shouldRestartOnLaunch` ends in `&& !isAgentPane`, and
///   `RestoredSessionsDialog` is how one comes back), so every row that
///   survived a restart claiming to be live is stale by construction.
/// * **When a pane stops being live**, from the terminal's own published
///   liveness map. That covers the agent exiting by itself, the user ending the
///   session, closing the pane, and ending every detached session at once —
///   `paneExitProvider` covers only the first of those, by construction, so the
///   map is what is read here.
///
/// ## What it will not do
///
/// It never writes `completed`, `failed` or `cancelled`. Losing sight of a
/// session says nothing about how it ended, and three of the six older words
/// each assert an ending nobody witnessed. [SessionStatus.unknown] is the whole
/// answer: *it was running, and we cannot see it any more.*
///
/// It also never touches a row that has already reached a terminal status. A
/// user who ended a session gets `cancelled` from whoever wrote it; a pane
/// exiting a moment later must not overwrite that with a vaguer word.
class SessionLivenessReconciler {
  SessionLivenessReconciler({required this.sessionDao, this.onChanged});

  final SessionDao sessionDao;

  /// Called with each row this moved, so the workspace can redraw. Null in the
  /// launch sweep, which runs before any of it exists.
  final void Function(String sessionId)? onChanged;

  /// Rows moved out of a live claim. Diagnostics, and what the tests count.
  int reconciled = 0;

  /// Sweeps **every** row that claims to be live against [livePaneIds].
  ///
  /// The launch pass. Costs one indexed read of a set that is normally empty;
  /// see [SessionDao.getClaimingLive].
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
  ///
  /// Keyed on the panes rather than on the session table so a process exiting
  /// costs one indexed lookup, not a scan. A row that has moved to another pane
  /// since is not returned by that lookup and so is not touched, which is the
  /// same rule `SessionAdoptionService._releasePane` applies for the same
  /// reason.
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
/// is one we have lost sight of.
///
/// Called from `main` with nothing but the database, before the window — and
/// therefore before any pane — exists, which is what makes the empty set below
/// a statement of fact rather than an assumption.
int markSessionsLostOnLaunch(SessionDao dao) =>
    SessionLivenessReconciler(sessionDao: dao).sweep(const {});

/// Pane ids that were running in [previous] and are not running in [next].
///
/// A pure function over the two published maps, so the listener below costs one
/// pass over the handful of panes on screen and touches the database only when
/// something actually stopped. A pane the map has dropped entirely counts —
/// closing a tab removes its entry rather than marking it exited.
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
/// watches would see no pane ever stop — silently, which is the worst failure
/// for a thing whose whole job is noticing. `AppShell` watches it, and its value
/// is `void` and never changes, so watching it costs the shell nothing after the
/// first build. `SessionEndingObserver` documents the same hazard.
///
/// Deliberately listens to the whole `TerminalSessionsState` rather than to a
/// per-pane family: this is the one subscriber in the app that has to hear about
/// a pane it does not already know, and `TerminalSessionsState`'s equality is by
/// collection identity, so a publish that did not rebuild the liveness map
/// compares equal and never reaches here.
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
  });
});
