import 'package:karmashala_session/session.dart';

import '../../sessions/application/sub_session_fold.dart';
import 'agent_states.dart';
import 'workspace_session_entry.dart';

/// The Sessions list's groups with every ended sub-session taken out of its
/// group and kept beneath the top-most ancestor the list shows. A live one
/// stays in its own group — running, waiting, or needing the person.
class SubSessionNesting {
  SubSessionNesting._(this.groups, this._nested, this._folds);

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
    for (final entry in byId.values) {
      final native = entry.native;
      if (native == null) continue;
      final anchor = anchorOf(entry);
      if (anchor == null) continue;
      (below[anchor] ??= []).add(native);
      if (!live(native)) (nested[anchor] ??= []).add(entry);
    }
    for (final children in nested.values) {
      children.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    }
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
      nested,
      folds,
    );
  }

  /// The groups as drawn, without the sub-sessions folded beneath a parent.
  final List<AgentStateGroup> groups;
  final Map<String, List<WorkspaceSessionEntry>> _nested;
  final Map<String, SubSessionFold> _folds;

  /// The fold line under [entry], or null when nothing came from it.
  SubSessionFold? foldOf(WorkspaceSessionEntry entry) => _folds[entry.id];

  /// The ended sub-sessions kept beneath [parentId], newest first.
  List<WorkspaceSessionEntry> nestedUnder(String parentId) =>
      _nested[parentId] ?? const [];
}
