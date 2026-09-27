import 'dart:async';

import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_agent_status/karmashala_agent_status.dart'
    show sameStatusEvidence;
import 'package:karmashala_core/util.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_notifications/watched.dart';

import '../../../core/data/data_client.dart';

export 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show SessionStatusEntry, WatchCoverage;

/// Every session's status **as the server keeps it** (slice 5c): the server
/// watches each session worth a status — the agents it runs from their hooks
/// and screens, the rest from hooks and transcripts — and tells this app each
/// move on the data channel. This is the copy the badges, the lists, the
/// waits and the automations' event rules read. It computes nothing.
class SessionStatuses {
  SessionStatuses(this._client, {required this.clock}) {
    _subscription = _client.attentionChanges.listen(_onChange);
  }

  final DataClient _client;
  final Clock clock;
  late final StreamSubscription<AttentionChange> _subscription;

  final _changes = StreamController<void>.broadcast(sync: true);
  final _statusChanges = StreamController<SessionStatusEntry>.broadcast(
    sync: true,
  );
  final _removals = StreamController<String>.broadcast(sync: true);
  final _coverage = StreamController<WatchCoverage?>.broadcast(sync: true);

  /// Every watched session now.
  List<SessionStatusEntry> get entries =>
      List.unmodifiable(_client.sessionStatuses.values);

  int get trackedCount => _client.sessionStatuses.length;

  /// How much of the watch set the server's last cycle reached, or null
  /// before it has said.
  WatchCoverage? get coverage => _client.watchCoverage;

  /// The status of the workspace row [openId], or null when it is not
  /// watched.
  AgentStatusReport? reportForOpenId(String openId) =>
      _client.sessionStatuses[openId]?.report;

  /// The status of one agent session, by the key hooks name it with.
  AgentStatusReport? reportForKey(AgentSessionKey key) {
    for (final entry in _client.sessionStatuses.values) {
      if (entry.key == key) return entry.report;
    }
    return null;
  }

  /// The transcript the server reads for [openId], as the server's machine
  /// spells it — a file this app can open only when the server is local.
  String? transcriptPathForOpenId(String openId) =>
      _client.sessionStatuses[openId]?.session.stateFilePath;

  /// Each status that moved, as the server tells it. Synchronous, so two
  /// moves in one batch stay two.
  Stream<SessionStatusEntry> get statusChanges => _statusChanges.stream;

  /// Each workspace row the server stopped keeping a status for.
  Stream<String> get removals => _removals.stream;

  /// [coverage] now, and again each time the server says it moved.
  Stream<WatchCoverage?> get coverageReports =>
      Stream<WatchCoverage?>.multi((controller) {
        controller.add(coverage);
        final subscription = _coverage.stream.listen(
          controller.add,
          onDone: controller.close,
        );
        controller.onCancel = subscription.cancel;
      });

  /// The status of one workspace row and every later change. Always yields
  /// at once ([fallback], or `unknown`, while it is not watched) so a first
  /// await cannot hang; later only when the evidence moved.
  Stream<AgentStatusReport> reportsFor(
    String openId, {
    AgentStatusReport? fallback,
  }) {
    AgentStatusReport current() =>
        reportForOpenId(openId) ??
        fallback ??
        AgentStatusReport(
          agentId: '',
          sessionId: openId,
          status: AgentActivityStatus.unknown,
          source: AgentStatusSource.none,
          observedAt: clock.nowUtc(),
        );

    // `Stream.multi`, not `async*`: a generator suspended in `await for`
    // only notices cancellation at its next yield.
    return Stream<AgentStatusReport>.multi((controller) {
      var last = current();
      controller.add(last);
      final subscription = _changes.stream.listen((_) {
        final next = current();
        if (sameStatusEvidence(last, next)) return;
        last = next;
        controller.add(next);
      }, onDone: controller.close);
      controller.onCancel = subscription.cancel;
    });
  }

  void _onChange(AttentionChange change) {
    switch (change) {
      case SessionStatusChanged(:final entry):
        if (!_statusChanges.isClosed) _statusChanges.add(entry);
      case SessionStatusRemoved(:final openId):
        if (!_removals.isClosed) _removals.add(openId);
      case WatchCoverageChanged(:final coverage):
        if (!_coverage.isClosed) _coverage.add(coverage);
        return;
      default:
        return;
    }
    if (!_changes.isClosed) _changes.add(null);
  }

  void dispose() {
    unawaited(_subscription.cancel());
    unawaited(_changes.close());
    unawaited(_statusChanges.close());
    unawaited(_removals.close());
    unawaited(_coverage.close());
  }
}
