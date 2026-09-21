import 'package:agent_cli/descriptors.dart';
import 'package:flutter/foundation.dart' show immutable, listEquals;
import 'package:karmashala_session/session.dart';

import 'workspace_session_entry.dart';

/// How a state's group is drawn before the user touches it.
enum AgentStateFold {
  /// Always drawn whole: these are the states somebody has to act on or watch.
  open,

  /// The first [kReadyVisibleRows] rows, then a row that shows the rest.
  capped,

  /// Only its header until opened.
  folded,
}

/// Rows a [AgentStateFold.capped] group draws before it folds the rest.
const int kReadyVisibleRows = 8;

/// The Agents page's groups, in the order it draws them.
enum AgentState {
  needsYou('Needs you', AgentStateFold.open),
  working('Working', AgentStateFold.open),
  failed('Failed', AgentStateFold.open),
  ready('Ready', AgentStateFold.capped),
  ended('Ended', AgentStateFold.folded);

  const AgentState(this.label, this.fold);

  final String label;
  final AgentStateFold fold;
}

/// Which group one session belongs to, from the facts the app already holds.
///
/// [needsYou] is the attention machinery's verdict (see `needsYouProvider`);
/// [live] is the status registry's; [rowStatus] is the row's recorded
/// lifecycle, null for an imported conversation. A live status outranks the
/// record, and nothing here second-guesses either: a row the app has recorded
/// `completed` whose agent reads idle is Ended, as reported.
AgentState agentStateOf({
  required bool needsYou,
  required AgentActivityStatus? live,
  required SessionStatus? rowStatus,
  bool archived = false,
}) {
  if (needsYou || live == AgentActivityStatus.awaitingApproval) {
    return AgentState.needsYou;
  }
  if (live == AgentActivityStatus.working) return AgentState.working;
  if (live == AgentActivityStatus.failed) return AgentState.failed;
  // An imported conversation is history this app does not host.
  if (rowStatus == null || archived) return AgentState.ended;
  return switch (rowStatus) {
    SessionStatus.created ||
    SessionStatus.running ||
    SessionStatus.idle => AgentState.ready,
    // `unknown` is "lost sight of it": no pane of ours holds it, so it is not
    // ready for a prompt — resuming it is a separate act.
    SessionStatus.unknown ||
    SessionStatus.completed ||
    SessionStatus.failed ||
    SessionStatus.cancelled => AgentState.ended,
  };
}

/// One session waiting on the user that has no row to draw — its row was
/// deleted, or has not been read yet. Kept so the page and the count agree.
@immutable
class NeedsYouSource {
  const NeedsYouSource({required this.label, required this.imported});

  final String label;
  final bool imported;

  @override
  bool operator ==(Object other) =>
      other is NeedsYouSource &&
      other.label == label &&
      other.imported == imported;

  @override
  int get hashCode => Object.hash(label, imported);
}

/// One group's sessions, newest activity first.
@immutable
class AgentStateGroup {
  const AgentStateGroup(this.state, this.entries);

  final AgentState state;
  final List<WorkspaceSessionEntry> entries;

  bool get isEmpty => entries.isEmpty;
  int get length => entries.length;

  @override
  bool operator ==(Object other) =>
      other is AgentStateGroup &&
      other.state == state &&
      listEquals(other.entries, entries);

  @override
  int get hashCode => Object.hash(state, Object.hashAll(entries));
}

/// Every session sorted into the five groups, always all five and in
/// [AgentState] order. One pass over [entries] and one sort per group.
///
/// Every key of [needsYou] lands in Needs you: one with no entry is drawn from
/// its [NeedsYouSource], so the group's length is exactly the count.
List<AgentStateGroup> groupByAgentState(
  Iterable<WorkspaceSessionEntry> entries, {
  required Map<String, NeedsYouSource> needsYou,
  required Map<String, AgentActivityStatus> live,
}) {
  final buckets = {
    for (final state in AgentState.values) state: <WorkspaceSessionEntry>[],
  };
  final seen = <String>{};
  for (final entry in entries) {
    if (!seen.add(entry.id)) continue;
    final state = agentStateOf(
      needsYou: needsYou.containsKey(entry.id),
      live: live[entry.id],
      rowStatus: entry.rowStatus,
      archived: entry.native?.isArchived ?? false,
    );
    buckets[state]!.add(entry);
  }
  for (final MapEntry(key: id, value: source) in needsYou.entries) {
    if (seen.contains(id)) continue;
    buckets[AgentState.needsYou]!.add(
      WorkspaceSessionEntry(
        id: id,
        title: source.label,
        // No row, so nothing dates it; it sorts after every dated one.
        createdAt: DateTime.utc(1970),
      ),
    );
  }
  return [
    for (final state in AgentState.values)
      AgentStateGroup(
        state,
        List.unmodifiable(buckets[state]!..sort(compareByActivity)),
      ),
  ];
}

/// Newest activity first; the id breaks ties so an order never flickers.
int compareByActivity(WorkspaceSessionEntry a, WorkspaceSessionEntry b) {
  final byTime = b.activityAt.compareTo(a.activityAt);
  return byTime != 0 ? byTime : a.id.compareTo(b.id);
}

/// How many of a group's rows are drawn given whether the user opened it.
int visibleRowCount(AgentStateGroup group, {required bool expanded}) =>
    switch (group.state.fold) {
      AgentStateFold.open => group.length,
      AgentStateFold.capped =>
        expanded || group.length <= kReadyVisibleRows
            ? group.length
            : kReadyVisibleRows,
      AgentStateFold.folded => expanded ? group.length : 0,
    };
