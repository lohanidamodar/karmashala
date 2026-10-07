import 'package:karmashala_ui/rows.dart' show compactAge;

import '../../explorer/application/agent_states.dart';
import 'overview_board.dart';

/// Mission control's tiles: lanes with something live or finished today, by
/// attention, and the [quiet] ones that fold into one line at the end.
({List<OverviewLane> live, List<OverviewLane> quiet}) arrangeTiles(
  List<OverviewLane> lanes,
) {
  final live = [
    for (final lane in lanes)
      if (!_isQuietTile(lane)) lane,
  ];
  final latest = {for (final lane in live) lane.key: _lastActivity(lane)};
  live.sort((a, b) {
    final tier = _tier(a).compareTo(_tier(b));
    if (tier != 0) return tier;
    final byTime = latest[b.key]!.compareTo(latest[a.key]!);
    return byTime != 0 ? byTime : a.label.compareTo(b.label);
  });
  return (
    live: live,
    quiet: [
      for (final lane in lanes)
        if (_isQuietTile(lane)) lane,
    ],
  );
}

bool _isQuietTile(OverviewLane lane) => lane.isQuiet && lane.doneToday.isEmpty;

int _tier(OverviewLane lane) {
  if (lane.cards(BoardColumn.needsYou).isNotEmpty) return 0;
  if (lane.cards(BoardColumn.working).isNotEmpty) return 1;
  return 2;
}

DateTime _lastActivity(OverviewLane lane) {
  var latest = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  for (final card in [...marksOf(lane), ...lane.doneOlder]) {
    if (card.entry.activityAt.isAfter(latest)) latest = card.entry.activityAt;
  }
  return latest;
}

/// The sessions a tile draws as marks: live ones column by column, then what
/// finished today.
List<OverviewCard> marksOf(OverviewLane lane) => [
  ...lane.cards(BoardColumn.needsYou),
  ...lane.cards(BoardColumn.working),
  ...lane.cards(BoardColumn.ready),
  ...lane.doneToday,
];

/// How many of [count] marks fit in [rows] rows of [perRow], keeping the last
/// place for "+[more]" when they do not all fit.
({int shown, int more}) capMarks(
  int count, {
  required int perRow,
  int rows = 2,
}) {
  final room = (perRow < 1 ? 1 : perRow) * rows;
  if (count <= room) return (shown: count, more: 0);
  return (shown: room - 1, more: count - room + 1);
}

/// A parent's sub-sessions as dots under its mark: needs you, then working,
/// then the rest ([BoardColumn.done] stands for any other state), three at
/// most.
({List<BoardColumn> dots, int more}) childDots(ChildSummary children) {
  final all = [
    for (var i = 0; i < children.needsYou; i++) BoardColumn.needsYou,
    for (var i = 0; i < children.working; i++) BoardColumn.working,
    for (var i = children.needsYou + children.working; i < children.total; i++)
      BoardColumn.done,
  ];
  const most = 3;
  return all.length <= most
      ? (dots: all, more: 0)
      : (dots: all.sublist(0, most), more: all.length - most);
}

/// **The one session that matters most in [lane]**: the oldest wait, else
/// the working session that has run longest (busy before quiet), else the
/// newest ready one, else what finished last today.
OverviewCard? headlineOf(
  OverviewLane lane, {
  required DateTime? Function(String sessionId) waitingSince,
}) {
  OverviewCard? first(
    Iterable<OverviewCard> cards,
    int Function(OverviewCard a, OverviewCard b) compare,
  ) => cards.isEmpty ? null : (cards.toList()..sort(compare)).first;

  final asks = lane.cards(BoardColumn.needsYou);
  if (asks.isNotEmpty) {
    DateTime since(OverviewCard c) => waitingSince(c.id) ?? c.entry.activityAt;
    return first(asks, (a, b) => since(a).compareTo(since(b)));
  }
  final working = lane.cards(BoardColumn.working);
  if (working.isNotEmpty) {
    final busy = working.where((c) => c.state == AgentState.working);
    return first(
      busy.isEmpty ? working : busy,
      (a, b) => a.entry.createdAt.compareTo(b.entry.createdAt),
    );
  }
  int newest(OverviewCard a, OverviewCard b) =>
      b.entry.activityAt.compareTo(a.entry.activityAt);
  return first(lane.cards(BoardColumn.ready), newest) ??
      first(lane.doneToday, newest);
}

/// "1 needs you · 3 working · active 8m ago".
String tileFooter(OverviewLane lane, {required DateTime now}) {
  final needs = lane.cards(BoardColumn.needsYou).length;
  final working = lane.cards(BoardColumn.working).length;
  final ready = lane.cards(BoardColumn.ready).length;
  final done = lane.doneToday.length;
  final age = compactAge(now.difference(_lastActivity(lane)));
  return [
    if (needs > 0) '$needs needs you',
    if (working > 0) '$working working',
    if (ready > 0) '$ready ready',
    if (done > 0) '$done done today',
    age == 'now' ? 'active just now' : 'active $age ago',
  ].join(' · ');
}

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
    for (final card in [...marksOf(lane), ...lane.doneOlder]) {
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
