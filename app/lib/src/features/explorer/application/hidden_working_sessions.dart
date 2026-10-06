import 'package:agent_cli/descriptors.dart';
import 'package:flutter/foundation.dart' show immutable, setEquals;
import 'package:riverpod/riverpod.dart';

import '../../sessions/application/session_list_prefs.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_signals.dart';
import 'agent_state_providers.dart';
import 'session_context.dart';

/// The sessions "Hide while working" takes off every list, decided once so
/// the lists cannot disagree.
@immutable
class HiddenWorkingSessions {
  const HiddenWorkingSessions({this.ids = const {}, this.topLevel = const {}});

  static const none = HiddenWorkingSessions();

  final Set<String> ids;

  /// The hidden sessions whose parent is not hidden too: what "N working"
  /// counts, so a hidden parent's children are not counted again.
  final Set<String> topLevel;

  bool get isEmpty => ids.isEmpty;
  bool contains(String id) => ids.contains(id);

  /// How many of [listed] the line under a list stands for.
  int countIn(Iterable<String> listed) =>
      topLevel.isEmpty ? 0 : listed.where(topLevel.contains).length;

  @override
  bool operator ==(Object other) =>
      other is HiddenWorkingSessions &&
      setEquals(other.ids, ids) &&
      setEquals(other.topLevel, topLevel);

  @override
  int get hashCode => Object.hash(
    Object.hashAllUnordered(ids),
    Object.hashAllUnordered(topLevel),
  );
}

/// With the switch on: every session working (Quiet too) that needs nothing
/// and is not on screen, and beneath it its sub-sessions — all but one that
/// needs you, failed or is on screen. It follows the statuses the Agents page
/// groups by, so a session is back the moment it stops working.
final hiddenWorkingSessionsProvider =
    Provider.autoDispose<HiddenWorkingSessions>((ref) {
      if (!ref.watch(hideWorkingSessionsProvider)) {
        return HiddenWorkingSessions.none;
      }
      final live = ref.watch(liveAgentStatusesProvider);
      if (!live.containsValue(AgentActivityStatus.working)) {
        return HiddenWorkingSessions.none;
      }
      final needsYou = ref.watch(needsYouProvider);
      final onScreen = ref.watch(onScreenSessionIdProvider);
      final panel = ref.watch(panelSessionIdProvider);
      bool stays(String id) =>
          id == onScreen ||
          id == panel ||
          needsYou.containsKey(id) ||
          switch (live[id]) {
            AgentActivityStatus.awaitingApproval ||
            AgentActivityStatus.failed => true,
            _ => false,
          };

      final working = {
        for (final MapEntry(key: id, value: status) in live.entries)
          if (status == AgentActivityStatus.working && !stays(id)) id,
      };
      if (working.isEmpty) return HiddenWorkingSessions.none;

      // A parent is named when a row is made, so only membership moves it.
      ref.watchSessionKinds(const {SessionChangeKind.membership});
      final parentOf = <String, String>{};
      final childrenOf = <String, List<String>>{};
      for (final session in ref.read(sessionsDataProvider).getAll()) {
        final parent = session.parentSessionId;
        if (parent == null) continue;
        parentOf[session.id] = parent;
        (childrenOf[parent] ??= []).add(session.id);
      }

      final ids = {...working};
      final pending = [...working];
      while (pending.isNotEmpty) {
        for (final child in childrenOf[pending.removeLast()] ?? const []) {
          if (!stays(child) && ids.add(child)) pending.add(child);
        }
      }
      return HiddenWorkingSessions(
        ids: Set.unmodifiable(ids),
        topLevel: Set.unmodifiable({
          for (final id in ids)
            if (!ids.contains(parentOf[id])) id,
        }),
      );
    });
