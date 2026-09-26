import 'package:riverpod/riverpod.dart';

import '../../terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/pane_lifecycle.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:karmashala_session/session.dart';
import 'host_lifecycle/host_lifecycle_providers.dart';
import 'session_launch_refusal.dart';
import 'session_providers.dart';
import 'session_signals.dart';

/// **Takes a row out of `running` when nothing we can see is running it**: a
/// live pane of ours, observed not inferred, and only ever moved to `unknown`.
/// Rows whose host reports their lifecycle are left to it.
class SessionLivenessReconciler {
  SessionLivenessReconciler({
    required this.sessionDao,
    this.onChanged,
    this.followsHost,
  });

  final SessionDao sessionDao;

  /// Whether a row's status is its host's facts, so no pane edge may move it.
  final bool Function(Session session)? followsHost;

  /// Called with each row this moved, so the workspace can redraw. Null in the
  /// launch sweep, which runs before any of it exists.
  final void Function(String sessionId)? onChanged;

  /// Rows moved out of a live claim. Diagnostics, and what the tests count.
  int reconciled = 0;

  /// Sweeps every row that claims to be live and passes [where] against
  /// [livePaneIds] — the launch pass.
  int sweep(Set<String> livePaneIds, {bool Function(Session session)? where}) {
    var moved = 0;
    for (final session in sessionDao.getClaimingLive()) {
      if (where != null && !where(session)) continue;
      final paneId = session.paneId;
      if (paneId != null && livePaneIds.contains(paneId)) continue;
      _lose(session.id);
      moved++;
    }
    return moved;
  }

  /// Sweeps only the rows hosted by [paneIds]. Keyed on the panes, so a
  /// process exiting costs one lookup and a row that moved is not touched.
  int panesStopped(Iterable<String> paneIds) {
    var moved = 0;
    for (final session in sessionDao.getByPaneIds(paneIds)) {
      if (!session.status.claimsLive || _followsHost(session)) continue;
      _lose(session.id);
      moved++;
    }
    return moved;
  }

  /// The other edge: a pane of ours is running this row's agent again — a
  /// tmux session reattached after a restart, or one started again in its pane
  /// after it ended. Only the session the pane's own launch names is touched,
  /// and an archived row is left where the user put it.
  int panesStarted(
    Iterable<String> paneIds, {
    required String? Function(String paneId) sessionOfPane,
  }) {
    var moved = 0;
    for (final session in sessionDao.getByPaneIds(paneIds)) {
      if (session.status == SessionStatus.running ||
          session.isArchived ||
          _followsHost(session)) {
        continue;
      }
      final paneId = session.paneId;
      if (paneId == null || sessionOfPane(paneId) != session.id) continue;
      sessionDao.updateStatus(session.id, SessionStatus.running);
      reconciled++;
      onChanged?.call(session.id);
      moved++;
    }
    return moved;
  }

  bool _followsHost(Session session) => followsHost?.call(session) ?? false;

  void _lose(String sessionId) {
    sessionDao.updateStatus(sessionId, SessionStatus.unknown);
    reconciled++;
    onChanged?.call(sessionId);
  }
}

/// The launch pass: a row that survived a restart still claiming to be live is
/// one we lost sight of. Called before any pane exists, which is the point.
/// [where] narrows it to the rows no host feed will speak for.
int markSessionsLostOnLaunch(
  SessionDao dao, {
  bool Function(Session session)? where,
}) => SessionLivenessReconciler(sessionDao: dao).sweep(const {}, where: where);

/// Pane ids that were running in [previous] and are not in [next] — a pure
/// function, so the listener touches the database only when one stopped.
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

/// Pane ids running in [next] that were not running in [previous] — every
/// running one when there was no previous state, which is the first reading
/// after a restart.
Set<String> panesThatStartedRunning(
  Map<String, PaneLiveness>? previous,
  Map<String, PaneLiveness> next,
) => {
  for (final entry in next.entries)
    if (entry.value.isLive && !(previous?[entry.key]?.isLive ?? false))
      entry.key,
};

/// Watches the terminal's published liveness and reconciles it. **Watched, not
/// read**: Riverpod 3 pauses a provider nobody listens to, silently.
final sessionLivenessReconcilerProvider = Provider<void>((ref) {
  final reconciler = SessionLivenessReconciler(
    sessionDao: ref.read(sessionDaoProvider),
    onChanged: (sessionId) => ref
        .read(sessionsRevisionProvider.notifier)
        .changed(SessionChange.statusChanged(sessionId)),
    followsHost: ref.watch(sessionFollowsHostFactsProvider),
  );
  ref.listen(terminalSessionsControllerProvider, (previous, next) {
    final started = panesThatStartedRunning(previous?.liveness, next.liveness);
    if (started.isNotEmpty) {
      final panes = ref.read(terminalSessionsControllerProvider.notifier);
      reconciler.panesStarted(
        started,
        sessionOfPane: (paneId) =>
            panes.instanceFor(paneId)?.agentLaunch?.sessionId,
      );
    }
    final stopped = panesThatStoppedRunning(previous?.liveness, next.liveness);
    if (stopped.isEmpty) return;
    reconciler.panesStopped(stopped);
    // The same edge, and the only one on which a refusal is readable: the CLI
    // has printed it and exited. See [reportRefusedLaunches].
    reportRefusedLaunches(ref, stopped);
  });
});
