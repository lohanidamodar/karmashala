import 'package:karmashala_session/session.dart';

import '../../sessions/application/sub_session_fold.dart';
import 'agent_states.dart';
import 'workspace_session_entry.dart';

/// The Sessions list's groups with every sub-session taken out of its group
/// and kept beneath the top-most ancestor the list shows — a live one too, so
/// a child is never in a status group of its own and the fold's count is the
/// rows beneath it. One whose ancestors are all gone stays where it is.
class SubSessionNesting {
  SubSessionNesting._(this.groups, this._nested, this._live, this._folds);

  factory SubSessionNesting.of(List<AgentStateGroup> groups) {
    final stateOf = <String, AgentState>{};
    final byId = <String, WorkspaceSessionEntry>{};
    for (final group in groups) {
      for (final entry in group.entries) {
        stateOf[entry.id] = group.state;
        byId[entry.id] = entry;
      }
    }
    bool live(Session session) =>
        (stateOf[session.id] ?? AgentState.ended) != AgentState.ended;

    String? anchorOf(WorkspaceSessionEntry entry) {
      String? anchor;
      final seen = <String>{entry.id};
      var parent = entry.native?.parentSessionId;
      while (parent != null && byId.containsKey(parent) && seen.add(parent)) {
        anchor = parent;
        parent = byId[parent]!.native?.parentSessionId;
      }
      return anchor;
    }

    final below = <String, List<Session>>{};
    final nested = <String, List<WorkspaceSessionEntry>>{};
    final liveIds = <String>{};
    for (final entry in byId.values) {
      final native = entry.native;
      if (native == null) continue;
      final anchor = anchorOf(entry);
      if (anchor == null) continue;
      (below[anchor] ??= []).add(native);
      (nested[anchor] ??= []).add(entry);
      if (live(native)) liveIds.add(entry.id);
    }
    final ordered = {
      for (final MapEntry(key: id, value: children) in nested.entries)
        id: runningFirst(
          children,
          isLive: (e) => liveIds.contains(e.id),
          createdAt: (e) => e.createdAt,
        ),
    };
    final hidden = {
      for (final children in nested.values)
        for (final child in children) child.id,
    };
    final folds = <String, SubSessionFold>{
      for (final MapEntry(key: id, value: sessions) in below.entries)
        if (byId[id]?.native case final parent?)
          id: SubSessionFold.of(parent, sessions, isLive: live),
    };
    return SubSessionNesting._(
      [
        for (final group in groups)
          hidden.isEmpty
              ? group
              : AgentStateGroup(group.state, [
                  for (final entry in group.entries)
                    if (!hidden.contains(entry.id)) entry,
                ]),
      ],
      ordered,
      liveIds,
      folds,
    );
  }

  /// The groups as drawn, without the sub-sessions kept beneath a parent.
  final List<AgentStateGroup> groups;
  final Map<String, List<WorkspaceSessionEntry>> _nested;
  final Set<String> _live;
  final Map<String, SubSessionFold> _folds;

  /// The fold line under [entry], or null when nothing came from it.
  SubSessionFold? foldOf(WorkspaceSessionEntry entry) => _folds[entry.id];

  /// The sub-sessions drawn beneath [parentId]: the live ones first, newest
  /// first in each; only the live ones while [folded].
  List<WorkspaceSessionEntry> nestedUnder(
    String parentId, {
    bool folded = false,
  }) {
    final all = _nested[parentId] ?? const [];
    return folded
        ? [
            for (final e in all)
              if (_live.contains(e.id)) e,
          ]
        : all;
  }
}
