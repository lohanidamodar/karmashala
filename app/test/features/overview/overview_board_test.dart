import 'package:agent_cli/process.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/explorer/application/agent_states.dart';
import 'package:karmashala/src/features/explorer/application/workspace_session_entry.dart';
import 'package:karmashala/src/features/overview/application/overview_board.dart';
import 'package:karmashala_session/session.dart';

/// **The Board's model**: which column each state lands in, how sub-sessions
/// stack, what Done counts, how lanes form, and that order holds still.
void main() {
  final now = DateTime.utc(2026, 10, 6, 15);
  final startOfToday = DateTime.utc(2026, 10, 6);

  WorkspaceSessionEntry entry(
    String id, {
    String? parent,
    Duration age = Duration.zero,
    String env = 'windows',
    String repo = 'r1',
  }) => WorkspaceSessionEntry(
    id: id,
    title: 'T $id',
    createdAt: now.subtract(age),
    lastActiveAt: now.subtract(age),
    directory: EnvironmentPath(environmentId: env, path: '/src/$id'),
    native: Session(
      id: id,
      repositoryId: repo,
      agentInstallationId: 'a1',
      title: 'T $id',
      useWorktree: false,
      status: SessionStatus.running,
      createdAt: now.subtract(age),
      parentSessionId: parent,
    ),
  );

  List<AgentStateGroup> groups(
    Map<AgentState, List<WorkspaceSessionEntry>> by,
  ) => [
    for (final state in AgentState.values)
      AgentStateGroup(state, by[state] ?? const []),
  ];

  OverviewFacts facts({Map<String, String> projectOf = const {}}) =>
      OverviewFacts(
        projectOf: (e) => projectOf[e.id] ?? 'p1',
        machineOf: (e) => e.directory?.environmentId,
        agentOf: (_) => 'claude-code',
        projects: const [
          OverviewLaneKey('p1', 'Alpha'),
          OverviewLaneKey('p2', 'Beta'),
        ],
        machines: const [
          OverviewLaneKey('windows', 'Windows'),
          OverviewLaneKey('wsl-arch', 'WSL · arch'),
        ],
      );

  OverviewBoard build(
    List<AgentStateGroup> g, {
    OverviewFacts? with_,
    OverviewFilter filter = const OverviewFilter(),
    OverviewGroupBy groupBy = OverviewGroupBy.project,
    BoardOrderMemo? memo,
  }) => buildOverviewBoard(
    g,
    facts: with_ ?? facts(),
    filter: filter,
    groupBy: groupBy,
    startOfToday: startOfToday,
    memo: memo ?? BoardOrderMemo(),
  );

  List<String> ids(OverviewLane lane, BoardColumn column) => [
    for (final card in lane.cards(column)) card.entry.id,
  ];

  group('columns', () {
    test('every state lands in the column the owner chose', () {
      expect(columnOf(AgentState.needsYou), BoardColumn.needsYou);
      expect(columnOf(AgentState.failed), BoardColumn.needsYou);
      expect(columnOf(AgentState.working), BoardColumn.working);
      expect(columnOf(AgentState.quiet), BoardColumn.working);
      expect(columnOf(AgentState.ready), BoardColumn.ready);
      expect(columnOf(AgentState.ended), BoardColumn.done);
    });

    test('a board puts each session in its column, quiet dimmed', () {
      final board = build(
        groups({
          AgentState.needsYou: [entry('n')],
          AgentState.failed: [entry('f')],
          AgentState.working: [entry('w')],
          AgentState.quiet: [entry('q')],
          AgentState.ready: [entry('r')],
          AgentState.ended: [entry('e')],
        }),
      );
      final lane = board.lanes.single;
      expect(ids(lane, BoardColumn.needsYou), unorderedEquals(['n', 'f']));
      expect(ids(lane, BoardColumn.working), unorderedEquals(['w', 'q']));
      expect(ids(lane, BoardColumn.ready), ['r']);
      expect(lane.doneToday.map((c) => c.entry.id), ['e']);
      expect(
        lane
            .cards(BoardColumn.working)
            .singleWhere((c) => c.entry.id == 'q')
            .dimmed,
        isTrue,
      );
    });
  });

  group('lineage', () {
    test('children stack on the parent card and are counted there', () {
      final board = build(
        groups({
          AgentState.working: [entry('p'), entry('c1', parent: 'p')],
          AgentState.ready: [entry('c2', parent: 'c1')],
          AgentState.needsYou: [entry('c3', parent: 'p')],
        }),
      );
      final lane = board.lanes.single;
      expect(ids(lane, BoardColumn.working), ['p']);
      expect(ids(lane, BoardColumn.ready), isEmpty);
      final parent = lane.cards(BoardColumn.working).single;
      expect(parent.children!.total, 3);
      expect(parent.children!.needsYou, 1);
      expect(parent.children!.working, 1);
      expect(parent.children!.label, '↳ 3: 1 needs you, 1 working');
    });

    test('a child that needs you or failed also shows in Needs you, with '
        "its parent's title", () {
      final board = build(
        groups({
          AgentState.working: [entry('p')],
          AgentState.needsYou: [entry('c', parent: 'p')],
          AgentState.failed: [entry('g', parent: 'c')],
        }),
      );
      final needs = board.lanes.single.cards(BoardColumn.needsYou);
      expect(needs.map((c) => c.entry.id), unorderedEquals(['c', 'g']));
      expect(needs.firstWhere((c) => c.entry.id == 'c').breadcrumb, 'T p');
      expect(needs.firstWhere((c) => c.entry.id == 'g').breadcrumb, 'T c');
    });

    test('a live child of an ended parent keeps a card of its own', () {
      final board = build(
        groups({
          AgentState.ended: [entry('p')],
          AgentState.working: [entry('c', parent: 'p')],
        }),
      );
      final working = board.lanes.single.cards(BoardColumn.working).single;
      expect(working.entry.id, 'c');
      expect(working.breadcrumb, 'T p');
    });
  });

  group('done', () {
    test('counts only what ended today; older ones wait behind Show all', () {
      final board = build(
        groups({
          AgentState.ended: [
            entry('today', age: const Duration(hours: 14)),
            entry('yesterday', age: const Duration(hours: 16)),
          ],
        }),
      );
      final lane = board.lanes.single;
      expect(lane.doneToday.map((c) => c.entry.id), ['today']);
      expect(lane.doneOlder.map((c) => c.entry.id), ['yesterday']);
    });

    test('a lane with nothing live is quiet', () {
      final board = build(
        groups({
          AgentState.working: [entry('w')],
          AgentState.ended: [entry('e', repo: 'r2')],
        }),
        with_: facts(projectOf: {'e': 'p2'}),
      );
      expect(board.lanes.map((l) => (l.key, l.isQuiet)), [
        ('p1', false),
        ('p2', true),
      ]);
    });
  });

  group('lanes and filters', () {
    test('group by machine makes one lane per environment, in order', () {
      final board = build(
        groups({
          AgentState.working: [entry('a', env: 'wsl-arch'), entry('b')],
        }),
        groupBy: OverviewGroupBy.machine,
      );
      expect(board.lanes.map((l) => l.label), ['Windows', 'WSL · arch']);
      expect(ids(board.lanes.last, BoardColumn.working), ['a']);
    });

    test('several projects sit side by side; the rest are filtered out', () {
      final all = groups({
        AgentState.working: [entry('a'), entry('b')],
      });
      final f = facts(projectOf: {'b': 'p2'});
      expect(build(all, with_: f).lanes.map((l) => l.key), ['p1', 'p2']);
      expect(
        build(
          all,
          with_: f,
          filter: const OverviewFilter(projects: {'p2'}),
        ).lanes.map((l) => l.key),
        ['p2'],
      );
    });

    test('a state filter narrows the columns drawn', () {
      final board = build(
        groups({
          AgentState.working: [entry('w')],
          AgentState.ready: [entry('r')],
        }),
        filter: const OverviewFilter(columns: {BoardColumn.ready}),
      );
      expect(ids(board.lanes.single, BoardColumn.working), isEmpty);
      expect(ids(board.lanes.single, BoardColumn.ready), ['r']);
    });
  });

  group('stable order', () {
    test('cards keep their place through a flicker, and move only when '
        'their column changes', () {
      final memo = BoardOrderMemo();
      final a = entry('a', age: const Duration(minutes: 5));
      final b = entry('b', age: const Duration(minutes: 1));
      var board = build(
        groups({
          AgentState.working: [a, b],
        }),
        memo: memo,
      );
      expect(ids(board.lanes.single, BoardColumn.working), ['b', 'a']);

      // a's activity is newer now, and it flickers to quiet and back.
      final a2 = WorkspaceSessionEntry(
        id: 'a',
        title: a.title,
        createdAt: a.createdAt,
        lastActiveAt: now,
        directory: a.directory,
        native: a.native,
      );
      board = build(
        groups({
          AgentState.working: [a2, b],
        }),
        memo: memo,
      );
      expect(ids(board.lanes.single, BoardColumn.working), ['b', 'a']);
      board = build(
        groups({
          AgentState.quiet: [a2],
          AgentState.working: [b],
        }),
        memo: memo,
      );
      expect(ids(board.lanes.single, BoardColumn.working), ['b', 'a']);

      // Out to Needs you and back: now it moves, newest first.
      build(
        groups({
          AgentState.needsYou: [a2],
          AgentState.working: [b],
        }),
        memo: memo,
      );
      board = build(
        groups({
          AgentState.working: [a2, b],
        }),
        memo: memo,
      );
      expect(ids(board.lanes.single, BoardColumn.working), ['a', 'b']);
    });
  });

  group('strip', () {
    test('counts every visible session, the oldest wait and the spend', () {
      final board = build(
        groups({
          AgentState.needsYou: [entry('n1'), entry('n2', parent: 'w')],
          AgentState.failed: [entry('f')],
          AgentState.working: [entry('w')],
          AgentState.quiet: [entry('q')],
          AgentState.ready: [entry('r')],
          AgentState.ended: [entry('e')],
        }),
      );
      final strip = summarizeStrip(
        board,
        now: now,
        waitingSince: (id) => switch (id) {
          'n1' => now.subtract(const Duration(minutes: 3)),
          'n2' => now.subtract(const Duration(minutes: 14)),
          _ => null,
        },
        failingChecks: const {'w', 'elsewhere'},
        usageLimited: const {'r'},
        cost: (id) => switch (id) {
          'w' => (amount: 0.30, currency: 'USD'),
          'r' => (amount: 0.12, currency: 'USD'),
          _ => null,
        },
      );
      expect(strip.needsYou, 2);
      expect(strip.failed, 1);
      expect(strip.oldestWait, const Duration(minutes: 14));
      expect(strip.working, 2);
      expect(strip.ready, 1);
      expect(strip.failingChecks, 1);
      expect(strip.usageLimitHits, 1);
      expect(strip.spend, {'USD': closeTo(0.42, 1e-9)});
      expect(strip.spendRecorded, isTrue);
    });

    test('with no ACP cost, spend is not recorded rather than zero', () {
      final strip = summarizeStrip(
        build(
          groups({
            AgentState.working: [entry('w')],
          }),
        ),
        now: now,
        waitingSince: (_) => null,
        cost: (_) => null,
      );
      expect(strip.spendRecorded, isFalse);
      expect(strip.oldestWait, isNull);
    });
  });
}
