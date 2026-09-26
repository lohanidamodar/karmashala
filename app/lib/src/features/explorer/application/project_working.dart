import 'dart:async';

import 'package:agent_cli/descriptors.dart';
import 'package:riverpod/riverpod.dart';

import '../../notifications/application/notification_providers.dart';
import '../../notifications/application/session_status_registry.dart';

/// The workspace rows whose agent is in a turn right now, as the one status
/// registry observes it. A subscription, never a poll: it moves when a status
/// does, and a cycle that reconfirms every status moves nothing.
class WorkingSessions extends Notifier<Set<String>> {
  @override
  Set<String> build() {
    final registry = ref.watch(sessionStatusRegistryProvider);
    final moves = registry.statusChanges.listen(_moved);
    // A session that stops being watched leaves without a last status, and
    // only the watch set's size says so.
    final watched = registry.coverageReports.listen((_) => _prune(registry));
    ref.onDispose(() {
      unawaited(moves.cancel());
      unawaited(watched.cancel());
    });
    return {
      for (final entry in registry.entries)
        if (_isWorking(registry, entry.session.openId)) entry.session.openId,
    };
  }

  static bool _isWorking(SessionStatusRegistry registry, String openId) =>
      registry.reportForOpenId(openId)?.status == AgentActivityStatus.working;

  void _moved(SessionStatusEntry entry) {
    final id = entry.session.openId;
    final working = entry.report.status == AgentActivityStatus.working;
    if (working == state.contains(id)) return;
    state = working ? {...state, id} : ({...state}..remove(id));
  }

  void _prune(SessionStatusRegistry registry) {
    if (state.isEmpty) return;
    final kept = {
      for (final id in state)
        if (_isWorking(registry, id)) id,
    };
    if (kept.length != state.length) state = kept;
  }
}

final workingSessionsProvider = NotifierProvider<WorkingSessions, Set<String>>(
  WorkingSessions.new,
);
