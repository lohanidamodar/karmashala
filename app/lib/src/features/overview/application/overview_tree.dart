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

/// [board] as families. A tree is rooted at the topmost session in view of a
/// family: one at work, ready, or waiting on its sub-sessions starts one, and
/// a parent in the same lane heads its sub-sessions' family whatever its own
/// state — stopped, ended or waiting on the owner — so a family is never
/// split. A sub-session branches off its parent whatever its own state. A
/// family with a member at work or waiting on the owner is with its lane's
/// work, most urgent family first; the rest are ready to close, newest root
/// first. A session alone that has ended stays on no tree; a sub-session
/// whose parent is in another lane, or not on the board, is a root of its
/// own.
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
  String? linkOf(OverviewCard card) {
    final parent = card.parentId;
    return parent != null &&
            parent != card.id &&
            laneOf[parent] == laneOf[card.id]
        ? parent
        : null;
  }

  // A parent heads its family whatever its own state: one stopped, ended or
  // waiting on the owner keeps its sub-sessions under it.
  for (final id in members.toList()) {
    for (
      var up = linkOf(byId[id]!);
      up != null && members.add(up);
      up = linkOf(byId[up]!)
    ) {}
  }
  String? parentOf(OverviewCard card) => switch (linkOf(card)) {
    final parent? when members.contains(parent) => parent,
    _ => null,
  };

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

  bool atWork(OverviewTreeNode tree) => tree.drawn.any(
    (c) => c.column == BoardColumn.needsYou || c.column == BoardColumn.working,
  );
  int urgencyOf(OverviewTreeNode tree) => tree.drawn
      .map((c) => overviewUrgency(c.state))
      .reduce((a, b) => a < b ? a : b);
  final workIn = <String, List<OverviewTreeNode>>{};
  final ready = <OverviewTreeNode>[];
  void file(OverviewTreeNode tree) => atWork(tree)
      ? (workIn[laneOf[tree.card.id]!] ??= []).add(tree)
      : ready.add(tree);
  for (final lane in board.lanes) {
    for (final card in [
      ...lane.cards(BoardColumn.needsYou),
      ...lane.cards(BoardColumn.working),
      ...lane.cards(BoardColumn.ready),
      ...lane.doneToday,
      ...lane.doneOlder,
    ]) {
      if (!members.contains(card.id) ||
          parentOf(card) != null ||
          laneOf[card.id] != lane.key ||
          placed.contains(card.id)) {
        continue;
      }
      file(grow(card));
    }
  }
  // A cycle of parents has no top, so none of it was grown above. It is
  // rooted where the walk up from one of its sessions comes back round, and
  // grown whole from there: a sub-session hanging off the cycle stays in
  // its family, and the family is filed by all of it.
  for (final card in byId.values) {
    if (!members.contains(card.id) || placed.contains(card.id)) continue;
    final seen = <String>{};
    var top = card;
    while (seen.add(top.id)) {
      final up = parentOf(top);
      if (up == null) break;
      top = byId[up]!;
    }
    file(grow(placed.contains(top.id) ? card : top));
  }
  final work = <(OverviewLane, List<OverviewTreeNode>)>[
    for (final lane in board.lanes)
      if (workIn[lane.key] case final trees?)
        (
          lane,
          [
            for (final (_, tree)
                in (trees.indexed.toList()..sort((a, b) {
                  final rank = urgencyOf(a.$2).compareTo(urgencyOf(b.$2));
                  return rank != 0 ? rank : a.$1.compareTo(b.$1);
                })))
              tree,
          ],
        ),
  ];
  ready.sort(
    (a, b) => b.card.entry.activityAt.compareTo(a.card.entry.activityAt),
  );
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
