import 'package:flutter/foundation.dart' show immutable;

import '../../explorer/application/agent_states.dart';
import '../../explorer/application/workspace_session_entry.dart';

/// The Board's four columns, left to right.
enum BoardColumn {
  needsYou('Needs you'),
  working('Working'),
  ready('Ready'),
  done('Done');

  const BoardColumn(this.label);

  final String label;
}

/// Where a session of [state] sits. The Agents lens's states, so the two
/// views cannot disagree about a session.
BoardColumn columnOf(AgentState state) => switch (state) {
  AgentState.needsYou || AgentState.failed => BoardColumn.needsYou,
  AgentState.working || AgentState.quiet => BoardColumn.working,
  AgentState.ready => BoardColumn.ready,
  AgentState.ended => BoardColumn.done,
};

/// What the Board's rows are.
enum OverviewGroupBy {
  project('Project'),
  machine('Machine');

  const OverviewGroupBy(this.label);

  final String label;
}

/// One lane's identity: a project id or an environment id, and its name.
@immutable
class OverviewLaneKey {
  const OverviewLaneKey(this.id, this.label);

  final String id;
  final String label;

  @override
  bool operator ==(Object other) =>
      other is OverviewLaneKey && other.id == id && other.label == label;

  @override
  int get hashCode => Object.hash(id, label);
}

/// The facts the Board files a session by, read from the replicas.
/// [projects] and [machines] are the lanes in the order they are drawn.
class OverviewFacts {
  const OverviewFacts({
    required this.projectOf,
    required this.machineOf,
    required this.agentOf,
    required this.projects,
    required this.machines,
  });

  final String? Function(WorkspaceSessionEntry entry) projectOf;
  final String? Function(WorkspaceSessionEntry entry) machineOf;
  final String? Function(WorkspaceSessionEntry entry) agentOf;
  final List<OverviewLaneKey> projects;
  final List<OverviewLaneKey> machines;
}

/// The lane of a session whose project or machine is not known.
const String kOverviewUnfiledLane = '';

/// What narrows the picture. A null set means "all".
@immutable
class OverviewFilter {
  const OverviewFilter({
    this.projects,
    this.agents,
    this.machines,
    this.columns,
  });

  final Set<String>? projects;
  final Set<String>? agents;
  final Set<String>? machines;
  final Set<BoardColumn>? columns;

  bool get isEmpty =>
      projects == null && agents == null && machines == null && columns == null;
}

/// A parent card's sub-sessions, by what they need.
@immutable
class ChildSummary {
  const ChildSummary({
    required this.total,
    required this.needsYou,
    required this.working,
  });

  final int total;

  /// Waiting on the user or failed.
  final int needsYou;
  final int working;

  /// "↳ 3: 1 needs you, 1 working".
  String get label {
    final parts = [
      if (needsYou > 0) '$needsYou needs you',
      if (working > 0) '$working working',
    ];
    return parts.isEmpty ? '↳ $total' : '↳ $total: ${parts.join(', ')}';
  }
}

/// One session as the Board draws it.
@immutable
class OverviewCard {
  const OverviewCard({
    required this.entry,
    required this.state,
    this.children,
    this.breadcrumb,
  });

  final WorkspaceSessionEntry entry;
  final AgentState state;

  /// The sub-sessions stacked on this card; null when it has none.
  final ChildSummary? children;

  /// The parent's title, on a sub-session drawn outside its parent's card.
  final String? breadcrumb;

  String get id => entry.id;
  BoardColumn get column => columnOf(state);

  /// Quiet reads as working, drawn dimmer.
  bool get dimmed => state == AgentState.quiet;
}

/// One row of the Board: a project or a machine.
class OverviewLane {
  OverviewLane({
    required this.key,
    required this.label,
    required this.live,
    required this.doneToday,
    required this.doneOlder,
  });

  final String key;
  final String label;

  /// Needs you, Working and Ready.
  final Map<BoardColumn, List<OverviewCard>> live;

  /// Ended today, newest first.
  final List<OverviewCard> doneToday;

  /// Ended before today, newest first: behind "Show all".
  final List<OverviewCard> doneOlder;

  /// The cards of a live column; Done is [doneToday] and [doneOlder].
  List<OverviewCard> cards(BoardColumn column) => switch (column) {
    BoardColumn.done => doneToday,
    _ => live[column] ?? const [],
  };

  /// Nothing needs the user, works or is ready.
  bool get isQuiet =>
      cards(BoardColumn.needsYou).isEmpty &&
      cards(BoardColumn.working).isEmpty &&
      cards(BoardColumn.ready).isEmpty;
}

/// The whole picture, and every visible session's state (stacked ones too).
class OverviewBoard {
  OverviewBoard({
    required this.lanes,
    required this.states,
    this.activeAt = const {},
  });

  static final empty = OverviewBoard(lanes: const [], states: const {});

  final List<OverviewLane> lanes;

  /// Every session the filters left in, by id: cards and stacked children.
  final Map<String, AgentState> states;

  /// When each of [states] was last active.
  final Map<String, DateTime> activeAt;
}

/// Each card's place in its column, kept between builds so a card moves only
/// when its column changes — never because its activity time ticked or its
/// status flickered within a column.
class BoardOrderMemo {
  final _placed = <String, (BoardColumn, DateTime)>{};

  DateTime _keyFor(OverviewCard card) {
    final kept = _placed[card.id];
    if (kept != null && kept.$1 == card.column) return kept.$2;
    return card.entry.activityAt;
  }

  void _keep(Map<String, (BoardColumn, DateTime)> next) {
    _placed
      ..clear()
      ..addAll(next);
  }
}

/// Builds the Board from the Agents lens's [groups]. Sub-sessions stack on
/// their top-most ancestor in view; one that needs the user or failed is also
/// drawn in Needs you with its parent's title, and a live one whose ancestor
/// is done keeps its own card.
OverviewBoard buildOverviewBoard(
  List<AgentStateGroup> groups, {
  required OverviewFacts facts,
  required OverviewFilter filter,
  required OverviewGroupBy groupBy,
  required DateTime startOfToday,
  required BoardOrderMemo memo,
}) {
  bool kept(WorkspaceSessionEntry entry) {
    if (filter.projects case final projects?) {
      if (!projects.contains(facts.projectOf(entry))) return false;
    }
    if (filter.agents case final agents?) {
      if (!agents.contains(facts.agentOf(entry))) return false;
    }
    if (filter.machines case final machines?) {
      if (!machines.contains(facts.machineOf(entry))) return false;
    }
    return true;
  }

  final stateOf = <String, AgentState>{};
  final byId = <String, WorkspaceSessionEntry>{};
  for (final group in groups) {
    for (final entry in group.entries) {
      if (byId.containsKey(entry.id) || !kept(entry)) continue;
      byId[entry.id] = entry;
      stateOf[entry.id] = group.state;
    }
  }

  String? parentIn(WorkspaceSessionEntry entry) {
    final parent = entry.native?.parentSessionId;
    return parent != null && byId.containsKey(parent) ? parent : null;
  }

  String? anchorOf(WorkspaceSessionEntry entry) {
    String? anchor;
    final seen = <String>{entry.id};
    var parent = parentIn(entry);
    while (parent != null && seen.add(parent)) {
      anchor = parent;
      parent = parentIn(byId[parent]!);
    }
    return anchor;
  }

  final cards = <OverviewCard>[];
  final stacked = <String, List<AgentState>>{};
  for (final entry in byId.values) {
    final state = stateOf[entry.id]!;
    final anchor = anchorOf(entry);
    if (anchor == null) continue;
    final ownColumn = columnOf(state);
    final anchorDone = columnOf(stateOf[anchor]!) == BoardColumn.done;
    final breadcrumb = byId[parentIn(entry)]?.title;
    if (anchorDone && ownColumn != BoardColumn.done) {
      cards.add(
        OverviewCard(entry: entry, state: state, breadcrumb: breadcrumb),
      );
      continue;
    }
    (stacked[anchor] ??= []).add(state);
    if (ownColumn == BoardColumn.needsYou) {
      cards.add(
        OverviewCard(entry: entry, state: state, breadcrumb: breadcrumb),
      );
    }
  }
  final hasCard = {for (final card in cards) card.id};
  for (final entry in byId.values) {
    if (hasCard.contains(entry.id) || anchorOf(entry) != null) continue;
    final below = stacked[entry.id];
    cards.add(
      OverviewCard(
        entry: entry,
        state: stateOf[entry.id]!,
        children: below == null
            ? null
            : ChildSummary(
                total: below.length,
                needsYou: below
                    .where((s) => columnOf(s) == BoardColumn.needsYou)
                    .length,
                working: below
                    .where((s) => columnOf(s) == BoardColumn.working)
                    .length,
              ),
      ),
    );
  }

  final laneOrder = switch (groupBy) {
    OverviewGroupBy.project => facts.projects,
    OverviewGroupBy.machine => facts.machines,
  };
  String laneOf(WorkspaceSessionEntry entry) =>
      switch (groupBy) {
        OverviewGroupBy.project => facts.projectOf(entry),
        OverviewGroupBy.machine => facts.machineOf(entry),
      } ??
      kOverviewUnfiledLane;

  final keys = <String, DateTime>{};
  final byLane = <String, Map<BoardColumn, List<(OverviewCard, DateTime)>>>{};
  for (final card in cards) {
    if (filter.columns case final columns?
        when !columns.contains(card.column)) {
      continue;
    }
    final key = memo._keyFor(card);
    keys[card.id] = key;
    ((byLane[laneOf(card.entry)] ??= {})[card.column] ??= []).add((card, key));
  }
  memo._keep({
    for (final card in cards)
      if (keys[card.id] case final key?) card.id: (card.column, key),
  });

  List<OverviewCard> ordered(List<(OverviewCard, DateTime)>? placed) {
    if (placed == null) return const [];
    placed.sort((a, b) {
      final byTime = b.$2.compareTo(a.$2);
      return byTime != 0 ? byTime : a.$1.id.compareTo(b.$1.id);
    });
    return List.unmodifiable([for (final (card, _) in placed) card]);
  }

  OverviewLane lane(String key, String label) {
    final columns = byLane[key] ?? const {};
    final done = ordered(columns[BoardColumn.done]);
    return OverviewLane(
      key: key,
      label: label,
      live: {
        for (final column in const [
          BoardColumn.needsYou,
          BoardColumn.working,
          BoardColumn.ready,
        ])
          column: ordered(columns[column]),
      },
      doneToday: [
        for (final card in done)
          if (!card.entry.activityAt.isBefore(startOfToday)) card,
      ],
      doneOlder: [
        for (final card in done)
          if (card.entry.activityAt.isBefore(startOfToday)) card,
      ],
    );
  }

  final known = {for (final lane in laneOrder) lane.id};
  return OverviewBoard(
    lanes: [
      for (final key in laneOrder)
        if (byLane.containsKey(key.id)) lane(key.id, key.label),
      for (final key in byLane.keys)
        if (!known.contains(key))
          lane(key, key == kOverviewUnfiledLane ? 'Elsewhere' : key),
    ],
    states: Map.unmodifiable({
      for (final MapEntry(key: id, value: state) in stateOf.entries)
        if (filter.columns?.contains(columnOf(state)) ?? true) id: state,
    }),
    activeAt: Map.unmodifiable({
      for (final entry in byId.values) entry.id: entry.activityAt,
    }),
  );
}

/// What a session's agent reported spending, over its protocol.
typedef SessionCost = ({double amount, String? currency});

/// The numbers above the Board.
@immutable
class OverviewStrip {
  const OverviewStrip({
    required this.needsYou,
    required this.failed,
    required this.oldestWait,
    required this.working,
    required this.ready,
    required this.failingChecks,
    required this.usageLimitHits,
    required this.spend,
  });

  final int needsYou;
  final int failed;

  /// How long the longest wait has run; null when no source dated one.
  final Duration? oldestWait;
  final int working;
  final int ready;
  final int failingChecks;
  final int usageLimitHits;

  /// Spend by currency, from the sessions whose agent reports it.
  final Map<String, double> spend;

  /// Whether any agent reported a cost at all. CLI sessions never do.
  bool get spendRecorded => spend.isNotEmpty;
}

/// The strip over every session [board] holds. Spend counts the sessions
/// active today whose agent reported a cost.
OverviewStrip summarizeStrip(
  OverviewBoard board, {
  required DateTime now,
  required DateTime? Function(String sessionId) waitingSince,
  Set<String> failingChecks = const {},
  Set<String> usageLimited = const {},
  required SessionCost? Function(String sessionId) cost,
  DateTime? startOfToday,
}) {
  var needsYou = 0, failed = 0, working = 0, ready = 0;
  DateTime? oldest;
  for (final MapEntry(key: id, value: state) in board.states.entries) {
    switch (state) {
      case AgentState.needsYou:
        needsYou++;
        final since = waitingSince(id);
        if (since != null && (oldest == null || since.isBefore(oldest))) {
          oldest = since;
        }
      case AgentState.failed:
        failed++;
      case AgentState.working || AgentState.quiet:
        working++;
      case AgentState.ready:
        ready++;
      case AgentState.ended:
        break;
    }
  }
  final spend = <String, double>{};
  for (final id in board.states.keys) {
    final active = board.activeAt[id];
    if (startOfToday != null &&
        (active == null || active.isBefore(startOfToday))) {
      continue;
    }
    final told = cost(id);
    if (told == null) continue;
    final currency = told.currency ?? '';
    spend[currency] = (spend[currency] ?? 0) + told.amount;
  }
  return OverviewStrip(
    needsYou: needsYou,
    failed: failed,
    oldestWait: oldest == null ? null : now.difference(oldest),
    working: working,
    ready: ready,
    failingChecks: failingChecks.where(board.states.containsKey).length,
    usageLimitHits: usageLimited.where(board.states.containsKey).length,
    spend: Map.unmodifiable(spend),
  );
}

/// An arrow key on the Board.
enum BoardMove { up, down, left, right }

/// The card an arrow lands on, from [from], over [grid] — lanes, then their
/// columns, then card ids as drawn. Up and down run through a column across
/// lanes; left and right reach the next column in the lane with a card. No
/// card yet picks the first; an edge stays put.
String? moveOnBoard(
  List<List<List<String>>> grid,
  String? from,
  BoardMove move,
) {
  (int, int, int)? at;
  for (final (l, lane) in grid.indexed) {
    for (final (c, column) in lane.indexed) {
      final i = column.indexOf(from ?? '');
      if (i >= 0) at = (l, c, i);
    }
  }
  if (at == null) {
    for (final lane in grid) {
      for (final column in lane) {
        if (column.isNotEmpty) return column.first;
      }
    }
    return null;
  }
  final (l, c, i) = at;
  switch (move) {
    case BoardMove.up || BoardMove.down:
      final run = [
        for (final lane in grid)
          if (c < lane.length) ...lane[c],
      ];
      final here = run.indexOf(from!);
      final next = here + (move == BoardMove.down ? 1 : -1);
      return next < 0 || next >= run.length ? from : run[next];
    case BoardMove.left || BoardMove.right:
      final step = move == BoardMove.right ? 1 : -1;
      final lane = grid[l];
      for (var k = c + step; k >= 0 && k < lane.length; k += step) {
        if (lane[k].isEmpty) continue;
        return lane[k][i < lane[k].length ? i : lane[k].length - 1];
      }
      return from;
  }
}
