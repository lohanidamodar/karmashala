import 'overview_board.dart';

/// The state filter after its counter for [tapped] is tapped: that state
/// alone, or none when it was already the one shown.
Set<BoardColumn>? counterTapped(
  Set<BoardColumn>? columns,
  BoardColumn tapped,
) => columns != null && columns.length == 1 && columns.contains(tapped)
    ? null
    : {tapped};

/// Sessions that ended today, across every lane.
int doneTodayOf(OverviewBoard board) =>
    board.lanes.fold(0, (sum, lane) => sum + lane.doneToday.length);

/// The mark an arrow lands on, from [from], over [tiles] — each tile's mark
/// ids as drawn. Left and right walk a tile; up and down reach the nearest
/// tile with marks, at the same place or its last. No mark yet picks the
/// first; an edge stays put.
String? moveOnTiles(List<List<String>> tiles, String? from, BoardMove move) {
  final t = tiles.indexWhere((tile) => tile.contains(from));
  if (t < 0) {
    for (final tile in tiles) {
      if (tile.isNotEmpty) return tile.first;
    }
    return null;
  }
  final i = tiles[t].indexOf(from!);
  switch (move) {
    case BoardMove.left || BoardMove.right:
      final next = i + (move == BoardMove.right ? 1 : -1);
      return next < 0 || next >= tiles[t].length ? from : tiles[t][next];
    case BoardMove.up || BoardMove.down:
      final step = move == BoardMove.down ? 1 : -1;
      for (var k = t + step; k >= 0 && k < tiles.length; k += step) {
        final tile = tiles[k];
        if (tile.isEmpty) continue;
        return tile[i < tile.length ? i : tile.length - 1];
      }
      return from;
  }
}

/// What an active-filter chip clears.
enum OverviewFilterKind { projects, agents, machines, archived }

/// One active filter, as its chip says it.
typedef OverviewActiveFilter = ({OverviewFilterKind kind, String label});

/// The chips under the counters: one per filter that narrows the picture.
/// The state filter is the counters' own, so it has none.
List<OverviewActiveFilter> activeFiltersOf(
  OverviewFilter filter, {
  required List<OverviewLaneKey> projects,
  required List<OverviewLaneKey> machines,
  required String Function(String agentId) agentName,
  required bool showArchived,
}) {
  String named(String noun, Set<String> kept, String Function(String) name) {
    if (kept.isEmpty) return '$noun: none';
    final names = [for (final id in kept) name(id)];
    return names.length <= 2
        ? '$noun: ${names.join(', ')}'
        : '$noun: ${names.first} +${names.length - 1}';
  }

  String Function(String) labelIn(List<OverviewLaneKey> keys) =>
      (id) => keys.where((k) => k.id == id).firstOrNull?.label ?? id;
  int byOrder(List<OverviewLaneKey> keys, String a, String b) {
    int at(String id) {
      final i = keys.indexWhere((k) => k.id == id);
      return i < 0 ? keys.length : i;
    }

    return at(a).compareTo(at(b));
  }

  return [
    if (filter.projects case final kept?)
      (
        kind: OverviewFilterKind.projects,
        label: named('Projects', {
          ...kept.toList()..sort((a, b) => byOrder(projects, a, b)),
        }, labelIn(projects)),
      ),
    if (filter.agents case final kept?)
      (
        kind: OverviewFilterKind.agents,
        label: named('Agent', {...kept.toList()..sort()}, agentName),
      ),
    if (filter.machines case final kept?)
      (
        kind: OverviewFilterKind.machines,
        label: named('Machine', {
          ...kept.toList()..sort((a, b) => byOrder(machines, a, b)),
        }, labelIn(machines)),
      ),
    if (showArchived)
      (kind: OverviewFilterKind.archived, label: 'Archived shown'),
  ];
}

/// The card [id] names on [board], wherever it is drawn; null when none.
OverviewCard? overviewCardOf(OverviewBoard board, String? id) {
  if (id == null) return null;
  for (final lane in board.lanes) {
    for (final card in [
      for (final column in BoardColumn.values) ...lane.cards(column),
      ...lane.doneOlder,
    ]) {
      if (card.id == id) return card;
    }
  }
  // A sub-session stacked on its parent is peeked from the parent's list.
  for (final below in board.children.values) {
    for (final card in below) {
      if (card.id == id) return card;
    }
  }
  return null;
}
