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

/// The dashboard's families, lane by lane, each in a place of its own that a
/// change of state never moves.
typedef OverviewForest = ({
  List<(OverviewLane, List<OverviewTreeNode>)> lanes,

  /// Every session drawn on a tree.
  Set<String> placed,
});

/// [board] as families. Every session in view that is live or ended today is
/// on a tree; a parent in the same lane heads its sub-sessions' family
/// whatever its own state, even one that ended before today, so a family is
/// never split. Sub-sessions branch off in the order they were started. In a
/// lane, [pinned] families come first, then the owner's hand [order], then
/// the rest by when their root started. A session's state never moves it.
OverviewForest overviewForestOf(
  OverviewBoard board, {
  Map<String, List<String>> order = const {},
  Set<String> pinned = const {},
}) {
  final byId = <String, OverviewCard>{};
  final laneOf = <String, String>{};
  final shown = <String>{};
  for (final lane in board.lanes) {
    for (final (card, today) in [
      for (final card in lane.cards(BoardColumn.needsYou)) (card, true),
      for (final card in lane.cards(BoardColumn.working)) (card, true),
      for (final card in lane.cards(BoardColumn.ready)) (card, true),
      for (final card in lane.doneToday) (card, true),
      for (final card in lane.doneOlder) (card, false),
    ]) {
      if (byId.containsKey(card.id)) continue;
      byId[card.id] = card;
      laneOf[card.id] = lane.key;
      if (today) shown.add(card.id);
    }
  }
  String? linkOf(OverviewCard card) {
    final parent = card.parentId;
    return parent != null &&
            parent != card.id &&
            laneOf[parent] == laneOf[card.id]
        ? parent
        : null;
  }

  // An older parent heads its family when a session below it is shown.
  final members = {...shown};
  for (final id in shown) {
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
  int byStart(OverviewCard a, OverviewCard b) {
    final at = a.entry.createdAt.compareTo(b.entry.createdAt);
    return at != 0 ? at : a.id.compareTo(b.id);
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
      for (final child in [...?under[card.id]]..sort(byStart))
        if (!placed.contains(child.id)) grow(child),
    ]);
  }

  final rootsIn = <String, List<OverviewTreeNode>>{};
  final tops = [
    for (final card in byId.values)
      if (members.contains(card.id) && parentOf(card) == null) card,
  ]..sort(byStart);
  for (final card in tops) {
    (rootsIn[laneOf[card.id]!] ??= []).add(grow(card));
  }
  // A cycle of parents has no top, so none of it was grown above. It is
  // rooted where the walk up from one of its sessions comes back round, and
  // grown whole from there.
  for (final card in [...byId.values]..sort(byStart)) {
    if (!members.contains(card.id) || placed.contains(card.id)) continue;
    final seen = <String>{};
    var top = card;
    while (seen.add(top.id)) {
      final up = parentOf(top);
      if (up == null) break;
      top = byId[up]!;
    }
    (rootsIn[laneOf[card.id]!] ??= []).add(
      grow(placed.contains(top.id) ? card : top),
    );
  }
  return (
    lanes: [
      for (final lane in board.lanes)
        if (rootsIn[lane.key] case final trees?)
          (
            lane,
            overviewFamilyOrderOf(trees, hand: order[lane.key], pinned: pinned),
          ),
    ],
    placed: placed,
  );
}

/// [trees] in their lane's order: [pinned] roots first, then those in the
/// owner's [hand] order, then the rest as given (by start time).
List<OverviewTreeNode> overviewFamilyOrderOf(
  List<OverviewTreeNode> trees, {
  List<String>? hand,
  Set<String> pinned = const {},
}) {
  final rank = {for (final (i, id) in (hand ?? const []).indexed) id: i};
  final ordered = [
    ...[
      for (final tree in trees)
        if (rank.containsKey(tree.card.id)) tree,
    ]..sort((a, b) => rank[a.card.id]!.compareTo(rank[b.card.id]!)),
    for (final tree in trees)
      if (!rank.containsKey(tree.card.id)) tree,
  ];
  return [
    for (final tree in ordered)
      if (pinned.contains(tree.card.id)) tree,
    for (final tree in ordered)
      if (!pinned.contains(tree.card.id)) tree,
  ];
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
