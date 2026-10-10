import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'overview_board.dart';
import 'overview_tiles.dart' show overviewCardOf;

/// How a sub-session drawn as a card is tied to its parent.
enum OverviewLinkKind {
  /// Its parent is drawn just before it, in the same list: indented, a
  /// connector to the parent on a desktop, a "child of" line on a phone.
  tied,

  /// Its parent is on the board, in another lane: a "↳ parent" line and a
  /// way to jump there, no connector.
  elsewhere,
}

/// One sub-session card's link to its parent.
@immutable
class OverviewLink {
  const OverviewLink({
    required this.parentId,
    required this.parentTitle,
    required this.kind,
    this.depth = 1,
  });

  final String parentId;
  final String parentTitle;
  final OverviewLinkKind kind;

  /// 1 under a top-level card, 2 under a sub-session, and so on.
  final int depth;

  @override
  bool operator ==(Object other) =>
      other is OverviewLink &&
      other.parentId == parentId &&
      other.parentTitle == parentTitle &&
      other.kind == kind &&
      other.depth == depth;

  @override
  int get hashCode => Object.hash(parentId, parentTitle, kind, depth);
}

/// [cards] as families, in order: a card, then each card after it whose
/// parent is already in its family. A sub-session nested under its parent
/// ([nestUnderParents]) always lands in its parent's family.
List<List<OverviewCard>> overviewFamiliesOf(List<OverviewCard> cards) {
  final families = <List<OverviewCard>>[];
  final idsOf = <Set<String>>[];
  for (final card in cards) {
    final parent = card.parentId;
    if (parent != null && idsOf.isNotEmpty && idsOf.last.contains(parent)) {
      families.last.add(card);
      idsOf.last.add(card.id);
    } else {
      families.add([card]);
      idsOf.add({card.id});
    }
  }
  return families;
}

/// The link each sub-session in [cards] has to its parent: tied when its
/// parent is in its family, elsewhere when the parent is on [board] in
/// another list. A card with no parent — never one, or detached — has none.
Map<String, OverviewLink> overviewLinksOf(
  List<OverviewCard> cards, {
  required OverviewBoard board,
}) {
  final links = <String, OverviewLink>{};
  for (final family in overviewFamiliesOf(cards)) {
    final depthOf = <String, int>{family.first.id: 0};
    for (final (i, card) in family.indexed) {
      final parent = card.parentId;
      if (parent == null) continue;
      final title =
          card.breadcrumb ?? overviewCardOf(board, parent)?.entry.title ?? '';
      if (i > 0 && depthOf.containsKey(parent)) {
        final depth = depthOf[parent]! + 1;
        depthOf[card.id] = depth;
        links[card.id] = OverviewLink(
          parentId: parent,
          parentTitle: title,
          kind: OverviewLinkKind.tied,
          depth: depth,
        );
      } else if (overviewCardOf(board, parent) != null) {
        links[card.id] = OverviewLink(
          parentId: parent,
          parentTitle: title,
          kind: OverviewLinkKind.elsewhere,
        );
      }
    }
  }
  return links;
}

/// [cards] less the sub-sessions under a folded parent of their own family:
/// a fold hides its family's descendants, and nothing drawn elsewhere.
List<OverviewCard> overviewUnfolded(
  List<OverviewCard> cards,
  Set<String> folded,
) {
  if (folded.isEmpty) return cards;
  final out = <OverviewCard>[];
  for (final family in overviewFamiliesOf(cards)) {
    final hidden = <String>{};
    for (final card in family) {
      final parent = card.parentId;
      if (parent != null &&
          (folded.contains(parent) || hidden.contains(parent)) &&
          card != family.first) {
        hidden.add(card.id);
        continue;
      }
      out.add(card);
    }
  }
  return out;
}

/// Every card on [board] whose parent is [parentId]: its direct
/// sub-sessions drawn as cards, in whichever lane they are.
List<OverviewCard> overviewChildCardsOf(OverviewBoard board, String parentId) {
  final out = <OverviewCard>[];
  final seen = <String>{};
  for (final lane in board.lanes) {
    for (final card in [
      for (final column in BoardColumn.values) ...lane.cards(column),
      ...lane.doneOlder,
    ]) {
      if (card.parentId == parentId && seen.add(card.id)) out.add(card);
    }
  }
  return out;
}

/// "3 sub-sessions · 2 working": a parent's direct sub-sessions drawn as
/// cards, counted by state.
String overviewChildrenLine(List<OverviewCard> children) =>
    subSessionSummary(children).replaceFirst('↳ ', '');

/// The parents whose sub-session cards are folded away, on this board.
class OverviewFoldedParents extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  void toggle(String parentId) => state = state.contains(parentId)
      ? ({...state}..remove(parentId))
      : {...state, parentId};
}

final overviewFoldedParentsProvider =
    NotifierProvider<OverviewFoldedParents, Set<String>>(
      OverviewFoldedParents.new,
    );

/// The card a pointer is over, or the keys are in: its family lights up.
@immutable
class OverviewLinkFocus {
  const OverviewLinkFocus(this.id, this.parentId);

  final String id;
  final String? parentId;
}

class OverviewLinkFocusController extends Notifier<OverviewLinkFocus?> {
  @override
  OverviewLinkFocus? build() => null;

  void enter(OverviewCard card) =>
      state = OverviewLinkFocus(card.id, card.parentId);

  void leave(String id) {
    if (state?.id == id) state = null;
  }
}

final overviewLinkFocusProvider =
    NotifierProvider<OverviewLinkFocusController, OverviewLinkFocus?>(
      OverviewLinkFocusController.new,
    );

/// Whether [card] lights up for [focus]: it is the focused card's parent, or
/// one of its sub-sessions.
bool overviewLinkLit(OverviewCard card, OverviewLinkFocus? focus) =>
    focus != null &&
    focus.id != card.id &&
    (focus.parentId == card.id || card.parentId == focus.id);
