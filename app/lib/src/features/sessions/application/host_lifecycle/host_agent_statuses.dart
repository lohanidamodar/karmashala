import 'dart:async';

import 'package:karmashala_agent_status/karmashala_agent_status.dart';
import 'package:riverpod/riverpod.dart';

/// What this machine's session host says the agent in each session it holds
/// is doing — the status the app **renders** for those sessions instead of
/// computing its own. Fed by the lifecycle subscriber: the snapshot on each
/// link, each change after it, and nothing once the link is lost.
class HostAgentStatuses {
  final _byRow = <String, HostedAgentStatus>{};
  final _changes = StreamController<String>.broadcast(sync: true);

  /// The row ids whose status moved, one per move.
  Stream<String> get changes => _changes.stream;

  /// What the host says the agent in the row [sessionId] is doing, or null.
  HostedAgentStatus? of(String sessionId) => _byRow[sessionId];

  /// Everything the host keeps now, replacing what was held.
  void replaceAll(List<HostedAgentStatus> statuses) {
    final gone = _byRow.keys.toSet();
    _byRow
      ..clear()
      ..addEntries([for (final s in statuses) MapEntry(s.sessionId, s)]);
    for (final sessionId in {...gone, ..._byRow.keys}) {
      _changed(sessionId);
    }
  }

  /// One row's status, or — null — the host let it go. Returns what it was.
  HostedAgentStatus? apply(String sessionId, HostedAgentStatus? status) {
    final before = status == null
        ? _byRow.remove(sessionId)
        : _byRow[sessionId];
    if (status != null) _byRow[sessionId] = status;
    _changed(sessionId);
    return before;
  }

  void _changed(String sessionId) {
    if (!_changes.isClosed) _changes.add(sessionId);
  }

  void dispose() => unawaited(_changes.close());
}

final hostAgentStatusesProvider = Provider<HostAgentStatuses>((ref) {
  final statuses = HostAgentStatuses();
  ref.onDispose(statuses.dispose);
  return statuses;
});
