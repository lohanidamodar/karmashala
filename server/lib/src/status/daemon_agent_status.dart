import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_agent_status/karmashala_agent_status.dart';
import 'package:karmashala_automations/store.dart' show CheckoutRows;
import 'package:karmashala_core/util.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:karmashala_store/database.dart';

import '../domain/host_session.dart';
import '../domain/screen_session.dart';
import '../domain/session_registry.dart';
import '../ssh/ssh_domain.dart';
import 'package:karmashala_host_protocol/protocol.dart';
import 'package:karmashala_session_engine/store.dart';

/// How often the daemon reads the screens of the agents it holds. The app's
/// registry cycled at the same pace: a status badge is what somebody is
/// looking at.
const Duration kDaemonStatusInterval = Duration(milliseconds: 1200);

/// **What the agent in each session this host holds is doing**, kept here —
/// not in whichever app happens to be open. Every hook the host takes and every
/// screen it holds goes through [HostedStatusKeeper] (the agent's adapter's
/// rules, hooks first); each change is published to watchers and on
/// [changes], for the companion, automations and `session_answer`.
///
/// Only sessions whose host id is a row's (`karmashala_<rowId>`) and whose row
/// names an agent installation are kept: a check the daemon runs has no
/// agent to read. An agent on an SSH box (slice 5d) is read the same way,
/// off the server's copy of its screen ([remoteScreens]) and the hooks its
/// box's host relays.
class DaemonAgentStatus {
  DaemonAgentStatus({
    required this.registry,
    required AppDatabase database,
    required this.publish,
    AgentRegistry agents = AgentRegistry.builtIn,
    Clock clock = const SystemClock(),
    this.interval = kDaemonStatusInterval,
    this.remoteScreens,
  }) : keeper = HostedStatusKeeper(agents: agents, clock: clock),
       _sessions = SessionDao(database),
       _checkouts = CheckoutRows(database);

  final SessionRegistry registry;

  /// Tells watchers a session's status moved — `HostedAgentStatus.toJson` —
  /// or, with null, that it is no longer kept.
  final void Function(String sessionId, Map<String, Object?>? status) publish;
  final Duration interval;

  /// The server's copies of the sessions on SSH boxes, read like its own.
  final Iterable<ScreenSession> Function()? remoteScreens;
  final HostedStatusKeeper keeper;
  final SessionDao _sessions;
  final CheckoutRows _checkouts;
  final _changes = StreamController<HostedAgentStatus>.broadcast(sync: true);

  /// Host ids already found to be no agent's row, so a check session is not
  /// looked up on every tick.
  final _notAgentRows = <String>{};
  Timer? _timer;

  /// Each status that moved, as it moves.
  Stream<HostedAgentStatus> get changes => _changes.stream;

  /// What the agent in the row [sessionId] is doing, while this host holds it.
  HostedAgentStatus? statusOf(String sessionId) => keeper.statusOf(sessionId);

  /// Every status kept, as a watcher that has just arrived is sent them.
  List<Map<String, Object?>> snapshot() => [
    for (final status in keeper.snapshot()) status.toJson(),
  ];

  /// The running session this host holds for the row [sessionId], or null.
  HostSession? runningSessionOf(String sessionId) {
    final session = registry.find(hostSessionIdOf(sessionId));
    if (session == null || session.lifecycle.hasEnded) return null;
    return session;
  }

  /// Whether the server holds row [sessionId]'s agent — one of its own
  /// PTYs, or a session on an SSH box it keeps a copy of (slice 5d).
  bool holds(String sessionId) => liveScreenOf(sessionId) != null;

  /// The screen of row [sessionId]'s running agent: one of this host's own
  /// PTYs, or its copy of a session on an SSH box. Null when neither runs it.
  ScreenSession? liveScreenOf(String sessionId) {
    final own = runningSessionOf(sessionId);
    if (own != null) return own;
    final id = hostSessionIdOf(sessionId);
    for (final screen in remoteScreens?.call() ?? const <ScreenSession>[]) {
      if (screen.id == id && !screen.lifecycle.hasEnded) return screen;
    }
    return null;
  }

  /// Types [bytes] into row [sessionId]'s agent as the server, past every
  /// client's write token: its own PTY, or a box session over the server's
  /// own link. False when neither can take them.
  bool typeAsServer(String sessionId, List<int> bytes) {
    if (bytes.isEmpty) return false;
    return switch (liveScreenOf(sessionId)) {
      final HostSession own => own.typeAsHost(Uint8List.fromList(bytes)),
      final RemoteSession box => box.type(bytes),
      _ => false,
    };
  }

  void start() {
    tick();
    _timer ??= Timer.periodic(interval, (_) => tick());
  }

  Future<void> close() async {
    _timer?.cancel();
    _timer = null;
    await _changes.close();
  }

  /// One pass: starts keeping each running agent session, reads each screen,
  /// and lets go of what has ended.
  void tick() {
    final running = <String>{};
    for (final session in <ScreenSession>[
      ...registry.sessions,
      ...?remoteScreens?.call(),
    ]) {
      if (session.lifecycle.hasEnded) continue;
      final rowId = _rowOf(session.id);
      if (rowId == null) continue;
      running.add(rowId);
      final tail = session.tailText(keeper.scanLinesFor(rowId));
      _announce(keeper.screen(rowId, tail));
    }
    for (final rowId in keeper.tracked.toList()) {
      if (running.contains(rowId)) continue;
      keeper.forget(rowId);
      publish(rowId, null);
    }
  }

  /// Folds in one hook the host took: the pane it names when it names one,
  /// else the row whose conversation it is about.
  void hook(AgentHookEvent hook) {
    final body = jsonEncode(hook.body);
    final report = keeper.classify(
      agentId: hook.agent,
      event: hook.event,
      body: body,
      receivedAt: hook.receivedAt,
    );
    final named = hook.sessionHeader;
    String? rowId;
    if (named != null && runningSessionOf(named) != null) {
      rowId = _rowOf(hostSessionIdOf(named));
    }
    rowId ??= keeper.sessionForConversation(hook.agent, report.sessionId);
    if (rowId == null) return;
    _announce(keeper.hookLanded(rowId, report, body: body));
  }

  void _announce(HostedAgentStatus? status) {
    if (status == null) return;
    publish(status.sessionId, status.toJson());
    if (!_changes.isClosed) _changes.add(status);
  }

  /// The row a host session runs, starting to keep it — or null for one that
  /// is no agent's row.
  String? _rowOf(String hostSessionId) {
    if (_notAgentRows.contains(hostSessionId)) return null;
    const prefix = 'karmashala_';
    if (!hostSessionId.startsWith(prefix)) {
      _notAgentRows.add(hostSessionId);
      return null;
    }
    // Row ids are UUIDs, which the host id's sanitising leaves alone; the
    // round trip below refuses anything it did not.
    final candidate = hostSessionId.substring(prefix.length);
    if (keeper.isTracked(candidate)) return candidate;
    final row = _sessions.getById(candidate);
    final agentId = row == null
        ? null
        : _checkouts.installation(row.agentInstallationId)?.agentId;
    if (row == null ||
        agentId == null ||
        hostSessionIdOf(row.id) != hostSessionId) {
      // Not remembered for a missing row: the app writes the row before it
      // opens the session, but a restarted host may read it back first.
      if (row != null) _notAgentRows.add(hostSessionId);
      return null;
    }
    keeper.track(
      row.id,
      agentId: agentId,
      conversationId: row.externalSessionId,
    );
    return row.id;
  }
}
