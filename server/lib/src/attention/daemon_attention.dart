import 'dart:async';
import 'dart:convert';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart' show AgentInstallation;
import 'package:agent_cli/read.dart' show ImportedSession;
import 'package:karmashala_agent_reporting/hooks.dart';
import 'package:karmashala_agent_reporting/status.dart';
import 'package:karmashala_agent_status/karmashala_agent_status.dart'
    show HostedAgentStatus;
import 'package:karmashala_core/util.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_notifications/attention.dart';
import 'package:karmashala_notifications/watched.dart';
import 'package:karmashala_session/events.dart'
    show FollowUp, FollowUpResolution;
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';

import '../data/data_service.dart';
import '../protocol/messages.dart' show AgentHookEvent;
import '../status/daemon_agent_status.dart';
import 'server_attention.dart';
import 'server_session_status.dart';
import 'watched_sessions.dart';

/// The server's session status and attention, put together over its store
/// (slice 5c): the hooks it takes ([hook]), its own reading of the agents it
/// runs ([DaemonAgentStatus]), the agents' transcripts on this machine, and
/// the data service every client is told through. `serve` builds one and
/// sets it as the data service's `attentionWork`.
class DaemonAttention {
  DaemonAttention({
    required AppDatabase database,
    required DataService data,
    required DaemonAgentStatus agentStatus,
    Future<Map<String, String>> Function()? transcripts,
    AgentRegistry agents = AgentRegistry.builtIn,
    Clock clock = const SystemClock(),
    void Function(List<InboxItem> items)? onNewItems,
    void Function(String sessionId)? onApprovalRequested,
    void Function()? onStatusMoved,
    void Function(String message)? log,
    Duration statusInterval = kStatusCycleInterval,
    Duration pollInterval = kAttentionPollInterval,
  }) : _data = data,
       _agentStatus = agentStatus,
       _sessions = SessionDao(database),
       _followUps = FollowUpDao(database) {
    receiver = AgentHookReceiver(
      registry: agents,
      reports: hookReports,
      clock: clock,
    );
    watched = WatchedSessions(
      rows: _StoreRows(database, data),
      hookReports: hookReports,
      clock: clock,
      isRunningOnHost: (id) => agentStatus.runningSessionOf(id) != null,
      transcriptPathFor: (id) => status.transcriptPathForOpenId(id),
    );
    status = ServerSessionStatus(
      statusService: AgentStatusService(
        registry: agents,
        hookReports: hookReports,
        clock: clock,
      ),
      agents: agents,
      loadSessions: watched.load,
      clock: clock,
      resolveTranscripts: transcripts,
      visibleSessionIds: () => attention.lookingAt,
      heldByHost: (session) =>
          agentStatus.runningSessionOf(session.openId) != null,
      hostStatusFor: (session) => agentStatus.statusOf(session.openId),
      interval: statusInterval,
      log: log,
    );
    attention = ServerAttention(
      status: status,
      tell: data.announce,
      clock: clock,
      followUps: _openFollowUps,
      resolveFollowUp: (rowId) => data.applyAsServer(
        FollowUpResolve(rowId, FollowUpResolution.dismissed),
      ),
      sessionOf: _watchedSessionOf,
      windows: () => data.subscriberCount,
      pollInterval: pollInterval,
      onNewItems: onNewItems,
      onApprovalRequested: onApprovalRequested,
      onStatusMoved: onStatusMoved,
    );
    _agentStatuses = agentStatus.changes.listen(_hostStatusMoved);
    data.addChangeListener(_rowsMoved);
  }

  final DataService _data;
  final DaemonAgentStatus _agentStatus;
  final SessionDao _sessions;
  final FollowUpDao _followUps;

  /// The latest hook per agent session, as the server took them.
  final AgentHookReports hookReports = AgentHookReports();
  late final AgentHookReceiver receiver;
  late final WatchedSessions watched;
  late final ServerSessionStatus status;
  late final ServerAttention attention;
  late final StreamSubscription<HostedAgentStatus> _agentStatuses;
  var _followUpsDue = false;

  void start() => attention.start();

  Future<void> close() async {
    _data.removeChangeListener(_rowsMoved);
    await _agentStatuses.cancel();
    await attention.close();
  }

  /// One hook the server took, folded in now: the report the agent's
  /// adapter reads off it, then the session it names.
  void hook(AgentHookEvent hook) {
    final report = receiver.handle(
      agentId: hook.agent,
      event: hook.event,
      body: jsonEncode(hook.body),
      observedAt: hook.receivedAt,
    );
    if (report.sessionId.isEmpty) return;
    status.hookReported(AgentSessionKey(report.agentId, report.sessionId));
  }

  void _hostStatusMoved(HostedAgentStatus moved) =>
      status.hostStatusMoved(moved.sessionId);

  /// A write the data service told: rows the watch set is chosen from, or
  /// the follow-ups the inbox files, may have moved.
  void _rowsMoved(List<DataChange> changes) {
    var rows = false;
    var followUps = false;
    for (final change in changes) {
      switch (change) {
        case FollowUpChanged():
          followUps = true;
        case SessionRowChanged() || SessionRowRemoved():
          rows = true;
          followUps = true;
        case ImportedChanged() || ImportedRemoved():
          rows = true;
        case InstallationChanged() || InstallationRemoved():
          rows = true;
        default:
          break;
      }
    }
    if (rows) watched.invalidate();
    if (followUps && !_followUpsDue) {
      // One read per turn, however many rows it wrote.
      _followUpsDue = true;
      scheduleMicrotask(() {
        _followUpsDue = false;
        attention.followUpsMoved();
      });
    }
  }

  List<InboxItem> _openFollowUps() {
    final open = _followUps.open();
    if (open.isEmpty) return const [];
    final agentOf = _agentOf();
    return [for (final followUp in open) ?_followUpItem(followUp, agentOf)];
  }

  InboxItem? _followUpItem(FollowUp followUp, Map<String, String> agentOf) {
    final session = _sessions.getById(followUp.sessionId);
    return followUpInboxItem(
      followUp,
      session,
      agentId: session == null
          ? ''
          : agentOf[session.agentInstallationId] ?? '',
    );
  }

  Map<String, String> _agentOf() => {
    for (final installation in _data.installations)
      installation.id: installation.agentId,
  };

  /// Row [sessionId] in the inbox's terms, keyed as its hooks key it.
  WatchedSession? _watchedSessionOf(String sessionId) {
    final session = _sessions.getById(sessionId);
    if (session == null) return null;
    final agentId = _agentOf()[session.agentInstallationId];
    final external = session.externalSessionId;
    return WatchedSession(
      key: AgentSessionKey(
        agentId ?? 'unknown',
        external == null || external.isEmpty ? session.id : external,
      ),
      label: session.title,
      openId: session.id,
      imported: false,
    );
  }

  /// What session [sessionId] asks of a person now, in a phone's words
  /// (`needs_approval`, `failed`), or null.
  String? attentionOf(String sessionId) {
    for (final waiting in attention.waiting) {
      if (waiting.session.openId != sessionId) continue;
      return switch (waiting.kind) {
        AttentionKind.needsInput => 'needs_approval',
        AttentionKind.failed => 'failed',
      };
    }
    return null;
  }

  /// The words for a usage limit [sessionId] hit, while its item is unseen.
  String? usageLimitOf(String sessionId) {
    for (final item in attention.inbox.pending) {
      if (item.kind == InboxItemKind.usageLimit &&
          item.session.openId == sessionId) {
        return item.detail;
      }
    }
    return null;
  }

  /// Whether the server runs row [sessionId]'s agent itself.
  bool runs(String sessionId) =>
      _agentStatus.runningSessionOf(sessionId) != null;
}

/// The watch set's rows, read from the server's store.
class _StoreRows implements WatchedRows {
  _StoreRows(AppDatabase database, this._data)
    : _sessions = SessionDao(database),
      _imported = ImportedSessionDao(database);

  final SessionDao _sessions;
  final ImportedSessionDao _imported;
  final DataService _data;

  @override
  List<Session> sessions() => _sessions.getAll();

  @override
  List<ImportedSession> imported() => _imported.getAll();

  @override
  List<AgentInstallation> installations() => _data.installations;
}
