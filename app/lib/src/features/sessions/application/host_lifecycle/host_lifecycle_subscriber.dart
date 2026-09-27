import 'dart:async';

import 'package:karmashala_agent_status/karmashala_agent_status.dart';
import 'package:karmashala_core/logging.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:karmashala_terminal_runtime/instances.dart'
    show kHostRedialDelays;

import 'host_lifecycle_source.dart';
import 'relayed_agent_hook.dart';

/// The one link to a host's lifecycle feed. The host writes its sessions'
/// lifecycle status itself — and tells every client of each row it writes
/// on the data channel, not here; this follows what it holds, hands each
/// relayed agent hook to [onHook], and dials again when the host goes away.
class HostLifecycleSubscriber {
  HostLifecycleSubscriber({
    required this.source,
    required this.sessions,
    required this.hasLivePane,
    this.onHook,
    this.onAgentStatuses,
    this.onAgentStatus,
    this.onAttached,
    this.onLost,
    this.mcpTools,
    this.companion,
    this.automations,
    this.panes,
    this.retryDelays = kHostRedialDelays,
    this.idleRetry = const Duration(seconds: 30),
    AppLogger? logger,
  }) : _log = logger ?? AppLogger.named('sessions.host_lifecycle');

  final HostLifecycleSource source;

  /// The rows, read to tell the host which ones this app's panes run.
  final SessionReads sessions;

  /// A live pane of this app's own runs its row, so the host is told to leave
  /// that row alone.
  final bool Function(String paneId) hasLivePane;

  /// Each hook once: a snapshot hook already applied on an earlier link is not
  /// applied again.
  final FutureOr<void> Function(RelayedAgentHook hook)? onHook;

  /// Every agent status the host keeps, whenever a link opens — and nothing,
  /// when it is lost: a host nobody can reach keeps no status this app may
  /// render.
  final void Function(List<HostedAgentStatus> statuses)? onAgentStatuses;

  /// One session's agent status moved, or — null — the host let it go.
  final void Function(String sessionId, HostedAgentStatus? status)?
  onAgentStatus;

  /// Each time a link opens — the host may be a new one, on a new endpoint.
  final void Function()? onAttached;

  /// Each time an open link is lost — the host may have died. Not on
  /// [dispose]. Whoever keeps the host up decides; this only dials again.
  final void Function()? onLost;

  /// Runs agents' tool calls the host forwards; offered on every link. Null
  /// runs none, and the host tells agents the app is not running.
  final HostMcpTools? mcpTools;

  /// This app's half of the phone companion the host serves; told of every
  /// link and every loss. Null leaves the host serving phones on its own.
  final HostCompanionPeer? companion;

  /// This app's half of the automations the host runs; told of every link and
  /// every loss. Null leaves the host running them on its own.
  final HostLinkPeer? automations;

  /// This app's terminal panes, reported to the host as facts; told of every
  /// link and every loss. Null reports none, and the host adopts nothing
  /// started by hand in them.
  final HostLinkPeer? panes;

  /// Waits before each dial after the link is lost, then [idleRetry] between
  /// dials; a pane starting on the host dials at once through [nudge].
  final List<Duration> retryDelays;
  final Duration idleRetry;

  final AppLogger _log;
  final Map<String, HostSessionState> _known = {};
  HostLifecycleFeed? _feed;
  StreamSubscription<SessionLifecycleEvent>? _events;
  StreamSubscription<RelayedAgentHook>? _hooks;
  StreamSubscription<HostMcpCall>? _mcpCalls;
  StreamSubscription<HostAgentStatusChange>? _agentStatuses;

  /// When the latest hook applied per [RelayedAgentHook.sessionKey] arrived.
  final Map<String, DateTime> _hookApplied = {};
  Timer? _retry;
  var _attempt = 0;
  var _dialing = false;
  var _disposed = false;
  String? _lastRefusal;

  bool get isWatching => _feed != null;

  /// Whether the host holds [sessionId], running or ended.
  bool knows(String sessionId) =>
      _known.containsKey(hostSessionIdOf(sessionId));

  bool isRunning(String sessionId) =>
      _known[hostSessionIdOf(sessionId)] == HostSessionState.running;

  /// Hands the host a hook this app took itself — on its own `/agent-hook`
  /// route or from a spool — so the server's checkpoint recorder hears the
  /// turns of panes it does not run. Nothing while no link is open: those
  /// turns go unrecorded, as they would with no server.
  void forwardHook(RelayedAgentHook hook) => _feed?.forwardHook(hook);

  /// Asks the host to answer a prompt in a session it runs. Throws
  /// [SessionPromptRefusal] when it will not, or no link is open.
  Future<SessionApprovalAnswer> answerPrompt(PromptAnswerRequest request) {
    final feed = _feed;
    if (feed == null) {
      return Future.error(
        const SessionPromptRefusal(
          'the session host is not reachable right now',
          noTerminal: true,
        ),
      );
    }
    return feed.answerPrompt(request);
  }

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
      feed = await source.open(runByClient: _runByThisApp());
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
      // Nothing written here: the host is the only writer, and the next one
      // to start marks what it does not hold.
      _known.clear();
      _scheduleRetry();
      return;
    }
    _attach(feed);
  }

  void _attach(HostLifecycleFeed feed) {
    _attempt = 0;
    _lastRefusal = null;
    _known
      ..clear()
      ..addEntries([
        for (final facts in feed.snapshot)
          MapEntry(facts.hostSessionId, facts.state),
      ]);
    _feed = feed;
    _events = feed.events.listen(_onEvent, onDone: _lost);
    onAgentStatuses?.call(feed.statusSnapshot);
    _agentStatuses = feed.agentStatuses.listen(
      (change) => onAgentStatus?.call(change.sessionId, change.status),
    );
    onAttached?.call();
    // A session the host no longer holds a hook for is forgotten here too.
    final held = {for (final hook in feed.hookSnapshot) hook.sessionKey};
    _hookApplied.removeWhere((key, _) => !held.contains(key));
    for (final hook in feed.hookSnapshot) {
      final applied = _hookApplied[hook.sessionKey];
      if (applied == null || hook.receivedAt.isAfter(applied)) {
        unawaited(_applyHook(hook));
      }
    }
    _hooks = feed.hooks.listen((hook) => unawaited(_applyHook(hook)));
    final tools = mcpTools;
    if (tools != null) {
      _mcpCalls = feed.mcpCalls.listen(
        (call) => unawaited(_runMcpCall(tools, call, feed)),
      );
      feed.offerMcpTools(tools.catalogue());
    }
    companion?.attached(feed);
    automations?.attached(feed);
    panes?.attached(feed);
  }

  /// Runs one forwarded call and answers it; a failure is the text the agent
  /// reads, exactly as this app's own server would have put it.
  Future<void> _runMcpCall(
    HostMcpTools tools,
    HostMcpCall call,
    HostLifecycleFeed feed,
  ) async {
    Object? result;
    try {
      result = await tools.call(
        call.tool,
        call.arguments,
        call.callerSessionId,
      );
    } on Object catch (error) {
      feed.answerMcpCall(call.callId, error: '$error');
      return;
    }
    try {
      feed.answerMcpCall(call.callId, result: result);
    } on Object catch (error) {
      // A result the wire cannot carry, reported rather than left hanging.
      feed.answerMcpCall(call.callId, error: '$error');
    }
  }

  /// Applies [hook]. Nothing waits on this app: the server held the agent,
  /// when it did, for its own checkpoint before relaying the hook.
  Future<void> _applyHook(RelayedAgentHook hook) async {
    _hookApplied[hook.sessionKey] = hook.receivedAt;
    try {
      await onHook?.call(hook);
    } on Object catch (error) {
      _log.warning('Applying a relayed agent hook failed: $error');
    }
  }

  void _onEvent(SessionLifecycleEvent event) {
    _known[event.hostSessionId] = event.facts.state;
  }

  void _lost() {
    final feed = _feed;
    _feed = null;
    _events = null;
    unawaited(_hooks?.cancel());
    _hooks = null;
    unawaited(_mcpCalls?.cancel());
    _mcpCalls = null;
    unawaited(_agentStatuses?.cancel());
    _agentStatuses = null;
    onAgentStatuses?.call(const []);
    companion?.detached();
    automations?.detached();
    panes?.detached();
    if (feed != null) unawaited(feed.close());
    if (_disposed) return;
    _log.info('Lost the session host lifecycle feed; dialing again.');
    onLost?.call();
    _scheduleRetry();
  }

  /// Rows still claiming to run whose pane is live in this app.
  List<String> _runByThisApp() => [
    for (final session in sessions.getClaimingLive())
      if (session.paneId case final paneId? when hasLivePane(paneId))
        session.id,
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
    await _mcpCalls?.cancel();
    _mcpCalls = null;
    await _agentStatuses?.cancel();
    _agentStatuses = null;
    if (_feed != null) {
      companion?.detached();
      automations?.detached();
      panes?.detached();
    }
    final feed = _feed;
    _feed = null;
    await feed?.close();
  }
}

/// Something of this app's that rides the host link: told when a link opens
/// and when it is lost.
abstract interface class HostLinkPeer {
  void attached(HostLifecycleFeed feed);
  void detached();
}

/// This app's half of the phone companion when the session host serves it.
abstract interface class HostCompanionPeer {
  /// A link opened: [feed] carries the host's companion calls and events, and
  /// takes this app's config, answers and notices.
  void attached(HostLifecycleFeed feed);

  /// The link is gone; the host serves phones on its own until the next one.
  void detached();
}

/// This app's agent tools, as the session host forwards calls to them.
abstract interface class HostMcpTools {
  /// What agents list, sent to the host on each link.
  List<Map<String, Object?>> catalogue();

  /// Runs [tool] as [callerSessionId]; throws to fail it.
  Future<Object?> call(
    String tool,
    Map<String, dynamic> arguments,
    String? callerSessionId,
  );
}
