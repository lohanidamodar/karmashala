part of 'terminal_sessions_controller.dart';

/// Which session each pane of **this window** runs, and the reverse — the one
/// answer to "where is session X here". A row's `pane_id` names whichever
/// window opened the session last, so it is believed only for a shell pane
/// this window holds: one the server adopted an agent in.
class PaneSessions {
  PaneSessions._(this._sessionByPane, this._panesBySession, this._livenessOf);

  /// [launched] is [TerminalSessionsState.launchedSessions]; [adopted] the
  /// session each of its shell panes was adopted into.
  factory PaneSessions._of(
    Map<String, String?> launched,
    Map<String, String> adopted,
    PaneLiveness Function(String paneId) livenessOf,
  ) {
    final byPane = <String, String>{
      for (final MapEntry(key: paneId, value: launchedAs) in launched.entries)
        paneId: ?(launchedAs ?? adopted[paneId]),
    };
    final bySession = <String, List<String>>{};
    for (final MapEntry(key: paneId, value: sessionId) in byPane.entries) {
      bySession.putIfAbsent(sessionId, () => []).add(paneId);
    }
    return PaneSessions._(byPane, bySession, livenessOf);
  }

  final Map<String, String> _sessionByPane;
  final Map<String, List<String>> _panesBySession;
  final PaneLiveness Function(String paneId) _livenessOf;

  /// The session pane [paneId] of this window runs, or null for a plain shell,
  /// a document, or a pane this window does not hold.
  String? sessionOf(String paneId) => _sessionByPane[paneId];

  /// A pane of this window showing [sessionId] whose liveness passes [where];
  /// with no [where], a live one before any other. Null when none does.
  String? paneOf(String sessionId, {bool Function(PaneLiveness)? where}) {
    final panes = _panesBySession[sessionId];
    if (panes == null) return null;
    if (where != null) {
      for (final paneId in panes) {
        if (where(_livenessOf(paneId))) return paneId;
      }
      return null;
    }
    if (panes.length == 1) return panes.single;
    for (final paneId in panes) {
      if (_livenessOf(paneId).isLive) return paneId;
    }
    return panes.first;
  }
}

/// [PaneSessions] for this window. Rebuilt when a pane comes or goes, and on a
/// row's placement only while there is a shell pane an agent could be adopted in.
final paneSessionsProvider = Provider<PaneSessions>((ref) {
  final launched = ref.watch(
    terminalSessionsControllerProvider.select((s) => s.launchedSessions),
  );
  final controller = ref.read(terminalSessionsControllerProvider.notifier);
  final shells = [
    for (final MapEntry(key: paneId, value: sessionId) in launched.entries)
      if (sessionId == null) paneId,
  ];
  final adopted = <String, String>{};
  if (shells.isNotEmpty) {
    ref.watchSessionKinds(const {SessionChangeKind.placement});
    // Oldest first, so the row a pane was adopted into first keeps it.
    for (final row in ref.read(sessionsDataProvider).getByPaneIds(shells)) {
      adopted.putIfAbsent(row.paneId!, () => row.id);
    }
  }
  return PaneSessions._of(
    launched,
    adopted,
    (paneId) =>
        controller.instanceFor(paneId)?.liveness.value ?? PaneLiveness.exited,
  );
});

/// The pane of this window showing [sessionId] — see [PaneSessions.paneOf].
/// Per session, so a pane opening elsewhere wakes only that session's row.
final paneOfSessionProvider = Provider.autoDispose.family<String?, String>(
  (ref, sessionId) =>
      ref.watch(paneSessionsProvider.select((p) => p.paneOf(sessionId))),
);

/// The session pane [paneId] of this window runs — see [PaneSessions.sessionOf].
final sessionOfPaneProvider = Provider.autoDispose.family<String?, String>(
  (ref, paneId) =>
      ref.watch(paneSessionsProvider.select((p) => p.sessionOf(paneId))),
);
