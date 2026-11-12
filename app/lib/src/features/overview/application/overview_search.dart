import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_core/util.dart' show matchesSearchAny;

import 'overview_board.dart';
import 'overview_tree.dart';

/// The dashboard's search: what is typed, the one match Enter opens, and a
/// count the strip's field takes focus on.
@immutable
class OverviewSearch {
  const OverviewSearch({this.query = '', this.current, this.focusAsks = 0});

  final String query;

  /// The pick: the match Enter opens, which ↑ and ↓ move; null for the first.
  final String? current;

  /// Raised by `/`: the field takes the keys each time it changes.
  final int focusAsks;

  bool get active => query.trim().isNotEmpty;

  @override
  bool operator ==(Object other) =>
      other is OverviewSearch &&
      other.query == query &&
      other.current == current &&
      other.focusAsks == focusAsks;

  @override
  int get hashCode => Object.hash(query, current, focusAsks);
}

class OverviewSearchController extends Notifier<OverviewSearch> {
  @override
  OverviewSearch build() => const OverviewSearch();

  void type(String query) {
    if (query == state.query) return;
    state = OverviewSearch(query: query, focusAsks: state.focusAsks);
  }

  void focus() => state = OverviewSearch(
    query: state.query,
    current: state.current,
    focusAsks: state.focusAsks + 1,
  );

  /// The match [step] places from the pick in [ids], stopping at the ends;
  /// null when there is none. With no pick yet, the first is the pick.
  String? step(List<String> ids, int step) {
    if (ids.isEmpty) return null;
    final at = ids.indexOf(state.current ?? '');
    final next = (at < 0 ? 0 : at + step).clamp(0, ids.length - 1);
    pick(ids[next]);
    return ids[next];
  }

  /// Makes [id] the match Enter opens.
  void pick(String? id) {
    if (id == state.current) return;
    state = OverviewSearch(
      query: state.query,
      current: id,
      focusAsks: state.focusAsks,
    );
  }

  void clear() => state = OverviewSearch(focusAsks: state.focusAsks);
}

final overviewSearchProvider =
    NotifierProvider<OverviewSearchController, OverviewSearch>(
      OverviewSearchController.new,
    );

/// Every session on [forest]'s trees in drawn order, folded and capped ones
/// included, whose title or [lineOf] matches [query].
List<OverviewCard> overviewSearchMatchesIn(
  OverviewForest forest,
  String query,
  String Function(OverviewCard card) lineOf,
) {
  if (query.trim().isEmpty) return const [];
  return [
    for (final card in overviewForestMembers(forest))
      if (matchesSearchAny(query, [card.entry.title, lineOf(card)])) card,
  ];
}

/// Every session on [forest]'s trees, lane by lane, each family root first
/// and then its sub-sessions as drawn unfolded.
Iterable<OverviewCard> overviewForestMembers(OverviewForest forest) sync* {
  final seen = <String>{};
  for (final (_, trees) in forest.lanes) {
    for (final tree in trees) {
      for (final card in tree.drawn) {
        if (seen.add(card.id)) yield card;
      }
    }
  }
}

/// The sessions above [id] on its tree, its root first; empty for a root or
/// a session on no tree.
List<String> overviewAncestorsIn(OverviewForest forest, String id) {
  List<String>? walk(OverviewTreeNode node, List<String> above) {
    if (node.card.id == id) return above;
    for (final child in node.children) {
      if (walk(child, [...above, node.card.id]) case final found?) {
        return found;
      }
    }
    return null;
  }

  for (final (_, trees) in forest.lanes) {
    for (final tree in trees) {
      if (walk(tree, const []) case final found?) return found;
    }
  }
  return const [];
}

/// The family [id] is drawn in, and the index of its lane; null when it is
/// on no tree.
({OverviewTreeNode tree, int lane})? overviewFamilyOf(
  OverviewForest forest,
  String? id,
) {
  if (id == null) return null;
  for (final (lane, (_, trees)) in forest.lanes.indexed) {
    for (final tree in trees) {
      if (tree.drawn.any((c) => c.id == id)) return (tree: tree, lane: lane);
    }
  }
  return null;
}

/// A session the dashboard is asked to bring into view: unfolded, selected
/// and scrolled to. Kept until the board has done it, so a request made
/// before the board was built is met when it is.
class OverviewRevealController extends Notifier<({String id, int ask})?> {
  var _asks = 0;

  @override
  ({String id, int ask})? build() => null;

  void reveal(String id) => state = (id: id, ask: ++_asks);

  /// The board has brought [ask] into view.
  void done(int ask) {
    if (state?.ask == ask) state = null;
  }
}

final overviewRevealProvider =
    NotifierProvider<OverviewRevealController, ({String id, int ask})?>(
      OverviewRevealController.new,
    );
