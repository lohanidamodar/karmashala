import 'package:flutter/foundation.dart' show immutable;

import '../../explorer/application/agent_states.dart';
import 'overview_board.dart';

/// One session on the dashboard's tree, and the sub-sessions branching off
/// it.
@immutable
class OverviewTreeNode {
  const OverviewTreeNode(this.card, [this.children = const []]);

  final OverviewCard card;
  final List<OverviewTreeNode> children;

  /// Every session below this one, depth first, as drawn.
  Iterable<OverviewCard> get descendants sync* {
    for (final child in children) {
      yield child.card;
      yield* child.descendants;
    }
  }

  /// This session, then [descendants].
  Iterable<OverviewCard> get drawn sync* {
    yield card;
    yield* descendants;
  }
}

/// The dashboard's families: what is at work, lane by lane, and what is
/// ready to close, each a tree whose root is the topmost session in view.
typedef OverviewForest = ({
  List<(OverviewLane, List<OverviewTreeNode>)> work,
  List<OverviewTreeNode> ready,

  /// Every session drawn on a tree.
  Set<String> placed,
});

/// [board] as families. A tree is rooted at a session at work, ready, or
/// waiting only on its sub-sessions; a sub-session in the same lane branches
/// off its parent whatever its own state, so a family is never split. A
/// sub-session whose parent is elsewhere — another lane, waiting on the
/// owner itself, or ended — is a root of its own.
OverviewForest overviewForestOf(OverviewBoard board) {
  final byId = <String, OverviewCard>{};
  final laneOf = <String, String>{};
  for (final lane in board.lanes) {
    for (final card in [
      ...lane.cards(BoardColumn.needsYou),
      ...lane.cards(BoardColumn.working),
      ...lane.cards(BoardColumn.ready),
      ...lane.doneToday,
      ...lane.doneOlder,
    ]) {
      if (byId.containsKey(card.id)) continue;
      byId[card.id] = card;
      laneOf[card.id] = lane.key;
    }
  }
  bool roots(OverviewCard card) =>
      card.column == BoardColumn.working ||
      card.column == BoardColumn.ready ||
      card.heldBySubSessions;

  final members = {
    for (final card in byId.values)
      if (roots(card)) card.id,
  };
  String? parentOf(OverviewCard card) {
    final parent = card.parentId;
    return parent != null &&
            parent != card.id &&
            members.contains(parent) &&
            laneOf[parent] == laneOf[card.id]
        ? parent
        : null;
  }

  // What waits on the owner or has ended joins a family, never starts one.
  for (var grew = true; grew;) {
    grew = false;
    for (final card in byId.values) {
      if (!members.contains(card.id) && parentOf(card) != null) {
        members.add(card.id);
        grew = true;
      }
    }
  }

  final under = <String, List<OverviewCard>>{};
  for (final card in byId.values) {
    if (!members.contains(card.id)) continue;
    if (parentOf(card) case final parent?) {
      (under[parent] ??= []).add(card);
    }
  }
  final placed = <String>{};
  OverviewTreeNode grow(OverviewCard card) {
    placed.add(card.id);
    return OverviewTreeNode(card, [
      for (final child in byUrgency(under[card.id] ?? const []))
        if (!placed.contains(child.id)) grow(child),
    ]);
  }

  bool isRoot(OverviewCard card) =>
      members.contains(card.id) && parentOf(card) == null;
  final work = <(OverviewLane, List<OverviewTreeNode>)>[];
  for (final lane in board.lanes) {
    final trees = [
      for (final card in byUrgency([
        ...lane.cards(BoardColumn.needsYou).where((c) => c.heldBySubSessions),
        ...lane.cards(BoardColumn.working),
      ]))
        if (isRoot(card) && laneOf[card.id] == lane.key) grow(card),
    ];
    if (trees.isNotEmpty) work.add((lane, trees));
  }
  final readyRoots = [
    for (final lane in board.lanes)
      for (final card in lane.cards(BoardColumn.ready))
        if (isRoot(card) && laneOf[card.id] == lane.key) card,
  ]..sort((a, b) => b.entry.activityAt.compareTo(a.entry.activityAt));
  final ready = [for (final card in readyRoots) grow(card)];
  // A cycle of parents leaves its sessions on no tree: each stands alone.
  for (final card in byId.values) {
    if (!members.contains(card.id) || placed.contains(card.id)) continue;
    final tree = grow(card);
    if (card.column == BoardColumn.ready) {
      ready.add(tree);
    } else if (work.indexWhere((g) => g.$1.key == laneOf[card.id]) case final at
        when at >= 0) {
      work[at].$2.add(tree);
    }
  }
  return (work: work, ready: ready, placed: placed);
}

/// [node]'s sessions as drawn: a node [folded] holds keeps its sub-sessions,
/// at any depth, out of view.
Iterable<OverviewCard> overviewDrawnOf(
  OverviewTreeNode node,
  Set<String> folded,
) sync* {
  yield node.card;
  if (folded.contains(node.card.id)) return;
  for (final child in node.children) {
    yield* overviewDrawnOf(child, folded);
  }
}

int _needsYou(Iterable<OverviewCard> cards) =>
    cards.where((c) => columnOf(c.state) == BoardColumn.needsYou).length;

/// "4 of 5 done · 1 working": a family's sub-sessions, the whole tree below
/// the root, by state.
String overviewFamilySummary(Iterable<OverviewCard> below) {
  final states = [for (final card in below) card.state];
  int count(bool Function(AgentState) test) => states.where(test).length;
  final done = count((s) => s == AgentState.ready || s == AgentState.ended);
  final needs = _needsYou(below);
  final working = count((s) => columnOf(s) == BoardColumn.working);
  return [
    '$done of ${states.length} done',
    if (needs > 0) '$needs needs you',
    if (working > 0) '$working working',
  ].join(' · ');
}

/// "7 sub-sessions".
String overviewSubSessionCount(int n) =>
    '$n ${n == 1 ? 'sub-session' : 'sub-sessions'}';

/// "7 sub-sessions · 6 of 7 done · 1 needs you": what a folded family hides.
String overviewFoldedSummary(List<OverviewCard> below) =>
    '${overviewSubSessionCount(below.length)} · '
    '${overviewFamilySummary(below)}';

/// "3 sub-sessions · 1 needs you": what a folded branch hides.
String overviewFoldedLine(List<OverviewCard> below) {
  final needs = _needsYou(below);
  return [
    overviewSubSessionCount(below.length),
    if (needs > 0) '$needs needs you',
  ].join(' · ');
}

/// The share of [node]'s sub-sessions that are done, for its avatar's ring;
/// null for a session with none.
double? overviewDoneShare(OverviewTreeNode node) {
  final below = node.descendants.toList();
  if (below.isEmpty) return null;
  final done = below
      .where((c) => c.state == AgentState.ready || c.state == AgentState.ended)
      .length;
  return done / below.length;
}

/// How many in [node] and below wait on the owner themselves: the count on
/// its avatar.
int overviewWaitingIn(OverviewTreeNode node) => node.drawn
    .where((c) => c.column == BoardColumn.needsYou && !c.heldBySubSessions)
    .length;
