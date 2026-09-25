import 'dart:async';

import 'package:karmashala_core/logging.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:karmashala_terminal_runtime/instances.dart'
    show kHostRedialDelays;

import 'host_lifecycle_source.dart';
import 'relayed_agent_hook.dart';

/// The one link to a host's lifecycle feed: records its snapshot and every
/// event after it through [recorder], hands each relayed agent hook to
/// [onHook], and dials again when the host goes away.
class HostLifecycleSubscriber {
  HostLifecycleSubscriber({
    required this.source,
    required this.recorder,
    required this.sessionDao,
    required this.runsOnThisMachine,
    required this.hasLivePane,
    this.onHook,
    this.onAttached,
    this.retryDelays = kHostRedialDelays,
    this.idleRetry = const Duration(seconds: 30),
    AppLogger? logger,
  }) : _log = logger ?? AppLogger.named('sessions.host_lifecycle');

  final HostLifecycleSource source;
  final SessionLifecycleRecorder recorder;
  final SessionDao sessionDao;

  /// Rows this host can speak for; the rest are left to their own host.
  final bool Function(Session session) runsOnThisMachine;

  /// A live pane runs its row whatever the host says, so it is never unseen.
  final bool Function(String paneId) hasLivePane;

  /// Each hook once: a snapshot hook already applied on an earlier link is not
  /// applied again.
  final void Function(RelayedAgentHook hook)? onHook;

  /// Each time a link opens — the host may be a new one, on a new endpoint.
  final void Function()? onAttached;

  /// Waits before each dial after the link is lost, then [idleRetry] between
  /// dials; a pane starting on the host dials at once through [nudge].
  final List<Duration> retryDelays;
  final Duration idleRetry;

  final AppLogger _log;
  final Map<String, HostSessionState> _known = {};
  HostLifecycleFeed? _feed;
  StreamSubscription<SessionLifecycleEvent>? _events;
  StreamSubscription<RelayedAgentHook>? _hooks;

  /// When the latest hook applied per [RelayedAgentHook.sessionKey] arrived.
  final Map<String, DateTime> _hookApplied = {};
  Timer? _retry;
  var _attempt = 0;
  var _answered = false;
  var _dialing = false;
  var _disposed = false;
  String? _lastRefusal;

  bool get isWatching => _feed != null;

  /// Whether the host holds [sessionId], running or ended.
  bool knows(String sessionId) =>
      _known.containsKey(hostSessionIdOf(sessionId));

  bool isRunning(String sessionId) =>
      _known[hostSessionIdOf(sessionId)] == HostSessionState.running;

  void start() => unawaited(_dial());

  /// Dials now when not watching: a pane just started a host.
  void nudge() {
    if (_disposed || _feed != null || _dialing) return;
    _retry?.cancel();
    unawaited(_dial());
  }

  Future<void> _dial() async {
    if (_disposed || _dialing) return;
    _dialing = true;
    HostLifecycleFeed? feed;
    try {
      feed = await source.open();
    } on Object catch (error) {
      _dialing = false;
      // Same build as the app, so a refusal is a fault to see, not a fallback.
      if ('$error' != _lastRefusal) {
        _lastRefusal = '$error';
        _log.error('The session host refused to be watched.', error);
      }
      _scheduleRetry();
      return;
    }
    _dialing = false;
    if (_disposed) {
      await feed?.close();
      return;
    }
    if (feed == null) {
      _nobodyListening();
      _scheduleRetry();
      return;
    }
    _attach(feed);
  }

  void _attach(HostLifecycleFeed feed) {
    _attempt = 0;
    _lastRefusal = null;
    final before = _runningHostIds();
    _known
      ..clear()
      ..addEntries([
        for (final facts in feed.snapshot)
          MapEntry(facts.hostSessionId, facts.state),
      ]);
    final candidates = _candidates();
    recorder.applySnapshot(
      feed.snapshot,
      sessionIdOf: (hostId) => sessionIdForHostId(hostId, candidates),
    );
    _recordGone(before.where((hostId) => !_known.containsKey(hostId)));
    _firstAnswer();
    _feed = feed;
    _events = feed.events.listen(_onEvent, onDone: _lost);
    onAttached?.call();
    // A session the host no longer holds a hook for is forgotten here too.
    final held = {for (final hook in feed.hookSnapshot) hook.sessionKey};
    _hookApplied.removeWhere((key, _) => !held.contains(key));
    for (final hook in feed.hookSnapshot) {
      final applied = _hookApplied[hook.sessionKey];
      if (applied == null || hook.receivedAt.isAfter(applied)) _applyHook(hook);
    }
    _hooks = feed.hooks.listen(_applyHook);
  }

  void _applyHook(RelayedAgentHook hook) {
    _hookApplied[hook.sessionKey] = hook.receivedAt;
    final onHook = this.onHook;
    if (onHook == null) return;
    try {
      onHook(hook);
    } on Object catch (error) {
      _log.warning('Applying a relayed agent hook failed: $error');
    }
  }

  void _onEvent(SessionLifecycleEvent event) {
    _known[event.hostSessionId] = event.facts.state;
    final candidates = _candidates();
    recorder.applyEvent(
      event,
      sessionIdOf: (hostId) => sessionIdForHostId(hostId, candidates),
    );
  }

  void _lost() {
    final feed = _feed;
    _feed = null;
    _events = null;
    unawaited(_hooks?.cancel());
    _hooks = null;
    if (feed != null) unawaited(feed.close());
    if (_disposed) return;
    _log.info('Lost the session host lifecycle feed; dialing again.');
    _scheduleRetry();
  }

  /// No host here, so none of the sessions it ran is running.
  void _nobodyListening() {
    final before = _runningHostIds();
    _known.clear();
    _recordGone(before);
    _firstAnswer();
  }

  /// Once per run: a row still claiming to run that no host knows was lost
  /// while the app was away. Replaces the blanket launch pass for this machine.
  void _firstAnswer() {
    if (_answered) return;
    _answered = true;
    for (final session in sessionDao.getClaimingLive()) {
      if (session.isArchived || knows(session.id)) continue;
      final paneId = session.paneId;
      if (paneId != null && hasLivePane(paneId)) continue;
      if (!runsOnThisMachine(session)) continue;
      recorder.recordUnseen(session.id);
    }
  }

  void _recordGone(Iterable<String> hostIds) {
    final ids = hostIds.toList();
    if (ids.isEmpty) return;
    final candidates = _candidates();
    for (final hostId in ids) {
      final sessionId = sessionIdForHostId(hostId, candidates);
      if (sessionId != null) recorder.recordUnseen(sessionId);
    }
  }

  Set<String> _runningHostIds() => {
    for (final entry in _known.entries)
      if (entry.value == HostSessionState.running) entry.key,
  };

  List<String> _candidates() => [
    for (final session in sessionDao.getAll())
      if (!session.isArchived) session.id,
  ];

  void _scheduleRetry() {
    if (_disposed) return;
    final delay = _attempt < retryDelays.length
        ? retryDelays[_attempt]
        : idleRetry;
    _attempt++;
    _retry?.cancel();
    _retry = Timer(delay, () => unawaited(_dial()));
  }

  Future<void> dispose() async {
    _disposed = true;
    _retry?.cancel();
    await _events?.cancel();
    _events = null;
    await _hooks?.cancel();
    _hooks = null;
    final feed = _feed;
    _feed = null;
    await feed?.close();
  }
}
