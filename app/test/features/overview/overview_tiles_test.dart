import 'package:agent_cli/process.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/explorer/application/agent_states.dart';
import 'package:karmashala/src/features/explorer/application/workspace_session_entry.dart';
import 'package:karmashala/src/features/overview/application/overview_board.dart';
import 'package:karmashala/src/features/overview/application/overview_tiles.dart';
import 'package:karmashala_session/session.dart';

/// **Mission control's model**: which project tile comes first, which
/// session heads it, what folds away as quiet, how the counters filter, how
/// the marks are capped and how the arrows move between them.
void main() {
  final now = DateTime.utc(2026, 10, 7, 15);
  final startOfToday = DateTime.utc(2026, 10, 7);

  WorkspaceSessionEntry entry(
    String id, {
    String? parent,
    Duration age = Duration.zero,
    Duration? started,
  }) => WorkspaceSessionEntry(
    id: id,
    title: 'T $id',
    createdAt: now.subtract(started ?? age),
    lastActiveAt: now.subtract(age),
    directory: EnvironmentPath(environmentId: 'windows', path: '/src/$id'),
    native: Session(
      id: id,
      repositoryId: 'r1',
      agentInstallationId: 'a1',
      title: 'T $id',
      useWorktree: false,
      status: SessionStatus.running,
      createdAt: now.subtract(started ?? age),
      parentSessionId: parent,
    ),
  );

  OverviewBoard build(
    Map<AgentState, List<WorkspaceSessionEntry>> by, {
    Map<String, String> projectOf = const {},
    OverviewFilter filter = const OverviewFilter(),
  }) => buildOverviewBoard(
    [
      for (final state in AgentState.values)
        AgentStateGroup(state, by[state] ?? const []),
    ],
    facts: OverviewFacts(
      projectOf: (e) => projectOf[e.id] ?? 'p1',
      machineOf: (e) => e.directory?.environmentId,
      agentOf: (_) => 'claude-code',
      projects: const [
        OverviewLaneKey('p1', 'Alpha'),
        OverviewLaneKey('p2', 'Beta'),
        OverviewLaneKey('p3', 'Gamma'),
        OverviewLaneKey('p4', 'Delta'),
      ],
      machines: const [OverviewLaneKey('windows', 'Windows')],
    ),
    filter: filter,
    groupBy: OverviewGroupBy.project,
    startOfToday: startOfToday,
    memo: BoardOrderMemo(),
  );

  group('attention order', () {
    test('needs you first, then working, then most recent activity', () {
      final board = build(
        {
          AgentState.ready: [
            entry('a-ready', age: const Duration(hours: 2)),
            entry('d-ready', age: const Duration(minutes: 5)),
          ],
          AgentState.working: [
            entry('b-work', age: const Duration(minutes: 30)),
          ],
          AgentState.needsYou: [entry('c-ask', age: const Duration(hours: 3))],
        },
        projectOf: const {
          'a-ready': 'p1',
          'b-work': 'p2',
          'c-ask': 'p3',
          'd-ready': 'p4',
        },
      );
      final tiles = arrangeTiles(board.lanes);
      expect(tiles.live.map((l) => l.label), [
        'Gamma',
        'Beta',
        'Delta',
        'Alpha',
      ]);
      expect(tiles.quiet, isEmpty);
    });

    test('a failed session counts as needing you', () {
      final board = build(
        {
          AgentState.working: [entry('w')],
          AgentState.failed: [entry('f', age: const Duration(hours: 1))],
        },
        projectOf: const {'w': 'p1', 'f': 'p2'},
      );
      expect(arrangeTiles(board.lanes).live.map((l) => l.label), [
        'Beta',
        'Alpha',
      ]);
    });

    test('a project with nothing live and nothing today folds as quiet; '
        'one that finished today stays a tile', () {
      final board = build(
        {
          AgentState.working: [entry('w')],
          AgentState.ended: [
            entry('today', age: const Duration(hours: 2)),
            entry('old', age: const Duration(days: 2)),
          ],
        },
        projectOf: const {'w': 'p1', 'today': 'p2', 'old': 'p3'},
      );
      final tiles = arrangeTiles(board.lanes);
      expect(tiles.live.map((l) => l.label), ['Alpha', 'Beta']);
      expect(tiles.quiet.map((l) => l.label), ['Gamma']);
    });
  });

  group('marks', () {
    test('live sessions by column, then what finished today', () {
      final lane = build({
        AgentState.ended: [entry('e', age: const Duration(hours: 1))],
        AgentState.ready: [entry('r')],
        AgentState.working: [entry('w')],
        AgentState.needsYou: [entry('n')],
      }).lanes.single;
      expect(marksOf(lane).map((c) => c.id), ['n', 'w', 'r', 'e']);
    });

    test('the row is capped at two rows with "+N"', () {
      expect(capMarks(5, perRow: 4), (shown: 5, more: 0));
      expect(capMarks(8, perRow: 4), (shown: 8, more: 0));
      expect(capMarks(12, perRow: 4), (shown: 7, more: 5));
      expect(capMarks(3, perRow: 0), (shown: 1, more: 2));
    });

    test('sub-session dots: three at most, the rest counted', () {
      final few = childDots(
        const ChildSummary(total: 2, needsYou: 1, working: 0),
      );
      expect(few.dots, [BoardColumn.needsYou, BoardColumn.done]);
      expect(few.more, 0);
      final many = childDots(
        const ChildSummary(total: 7, needsYou: 1, working: 3),
      );
      expect(many.dots, [
        BoardColumn.needsYou,
        BoardColumn.working,
        BoardColumn.working,
      ]);
      expect(many.more, 4);
    });
  });

  group('headline', () {
    test('the oldest wait wins', () {
      final lane = build({
        AgentState.needsYou: [entry('n1'), entry('n2')],
        AgentState.working: [entry('w', started: const Duration(hours: 5))],
      }).lanes.single;
      final pick = headlineOf(
        lane,
        waitingSince: (id) => switch (id) {
          'n1' => now.subtract(const Duration(minutes: 3)),
          'n2' => now.subtract(const Duration(minutes: 12)),
          _ => null,
        },
      );
      expect(pick?.id, 'n2');
    });

    test('an undated wait falls back to its last activity', () {
      final lane = build({
        AgentState.needsYou: [
          entry('n1', age: const Duration(minutes: 1)),
          entry('n2', age: const Duration(minutes: 40)),
        ],
      }).lanes.single;
      expect(
        headlineOf(
          lane,
          waitingSince: (id) =>
              id == 'n1' ? now.subtract(const Duration(minutes: 9)) : null,
        )?.id,
        'n2',
      );
    });

    test('else the longest-running working one, quiet only after busy', () {
      final lane = build({
        AgentState.working: [
          entry('w1', started: const Duration(minutes: 6)),
          entry('w2', started: const Duration(hours: 1)),
        ],
        AgentState.quiet: [entry('q', started: const Duration(hours: 9))],
        AgentState.ready: [entry('r')],
      }).lanes.single;
      expect(headlineOf(lane, waitingSince: (_) => null)?.id, 'w2');
    });

    test('else the newest ready one, else what finished last today', () {
      final ready = build({
        AgentState.ready: [
          entry('r1', age: const Duration(hours: 1)),
          entry('r2', age: const Duration(minutes: 2)),
        ],
      }).lanes.single;
      expect(headlineOf(ready, waitingSince: (_) => null)?.id, 'r2');

      final done = build({
        AgentState.ended: [
          entry('e1', age: const Duration(hours: 3)),
          entry('e2', age: const Duration(hours: 1)),
        ],
      }).lanes.single;
      expect(headlineOf(done, waitingSince: (_) => null)?.id, 'e2');
    });
  });

  group('footer', () {
    test('counts what is live and says when it was last active', () {
      final lane = build({
        AgentState.needsYou: [entry('n', age: const Duration(minutes: 8))],
        AgentState.working: [
          entry('w1', age: const Duration(minutes: 20)),
          entry('w2', age: const Duration(minutes: 30)),
          entry('q', age: const Duration(hours: 1)),
        ],
      }).lanes.single;
      expect(
        tileFooter(lane, now: now),
        '1 needs you · 3 working · active 8m ago',
      );
    });

    test('done today and just now', () {
      final lane = build({
        AgentState.ready: [entry('r')],
        AgentState.ended: [
          entry('e1', age: const Duration(hours: 1)),
          entry('e2', age: const Duration(hours: 2)),
        ],
      }).lanes.single;
      expect(
        tileFooter(lane, now: now),
        '1 ready · 2 done today · active just now',
      );
    });
  });

  group('counters', () {
    test('tapping a counter shows only that state; again clears it', () {
      expect(counterTapped(null, BoardColumn.working), {BoardColumn.working});
      expect(counterTapped({BoardColumn.working}, BoardColumn.working), null);
      expect(counterTapped({BoardColumn.working}, BoardColumn.ready), {
        BoardColumn.ready,
      });
      // A choice kept from the old State menu, two states at once.
      expect(
        counterTapped({
          BoardColumn.working,
          BoardColumn.ready,
        }, BoardColumn.ready),
        {BoardColumn.ready},
      );
    });

    test('done today counts every lane', () {
      final board = build(
        {
          AgentState.ended: [
            entry('a', age: const Duration(hours: 1)),
            entry('b', age: const Duration(hours: 2)),
            entry('old', age: const Duration(days: 3)),
          ],
        },
        projectOf: const {'a': 'p1', 'b': 'p2', 'old': 'p2'},
      );
      expect(doneTodayOf(board), 2);
    });
  });

  group('keyboard', () {
    final tiles = [
      ['a1', 'a2', 'a3'],
      ['b1'],
      <String>[],
      ['c1', 'c2'],
    ];

    test('no mark yet picks the first', () {
      expect(moveOnTiles(tiles, null, BoardMove.right), 'a1');
      expect(moveOnTiles(const [], null, BoardMove.right), isNull);
    });

    test('left and right walk a tile and stop at its edges', () {
      expect(moveOnTiles(tiles, 'a1', BoardMove.right), 'a2');
      expect(moveOnTiles(tiles, 'a3', BoardMove.right), 'a3');
      expect(moveOnTiles(tiles, 'a1', BoardMove.left), 'a1');
    });

    test('up and down reach the next tile with marks, at the same place '
        'or its last', () {
      expect(moveOnTiles(tiles, 'a3', BoardMove.down), 'b1');
      expect(moveOnTiles(tiles, 'b1', BoardMove.down), 'c1');
      expect(moveOnTiles(tiles, 'c2', BoardMove.up), 'b1');
      expect(moveOnTiles(tiles, 'a2', BoardMove.up), 'a2');
    });
  });

  group('active filters', () {
    const projects = [
      OverviewLaneKey('p1', 'Alpha'),
      OverviewLaneKey('p2', 'Beta'),
      OverviewLaneKey('p3', 'Gamma'),
    ];
    const machines = [
      OverviewLaneKey('windows', 'Windows'),
      OverviewLaneKey('wsl', 'WSL · arch'),
    ];
    List<String> labels(OverviewFilter filter, {bool archived = false}) => [
      for (final chip in activeFiltersOf(
        filter,
        projects: projects,
        machines: machines,
        agentName: (id) => id == 'codex' ? 'Codex' : id,
        showArchived: archived,
      ))
        chip.label,
    ];

    test('none while nothing narrows the picture', () {
      expect(labels(const OverviewFilter()), isEmpty);
      // The state is the counters' to show, never a chip.
      expect(
        labels(const OverviewFilter(columns: {BoardColumn.ready})),
        isEmpty,
      );
    });

    test('one chip per filter, naming what it keeps', () {
      expect(
        labels(
          const OverviewFilter(
            projects: {'p1', 'p3'},
            agents: {'codex'},
            machines: {'wsl'},
          ),
          archived: true,
        ),
        [
          'Projects: Alpha, Gamma',
          'Agent: Codex',
          'Machine: WSL · arch',
          'Archived shown',
        ],
      );
    });

    test('a long list is shortened, an empty one says so', () {
      expect(
        labels(const OverviewFilter(projects: {'p1', 'p2', 'p3', 'gone'})),
        ['Projects: Alpha +3'],
      );
      expect(labels(const OverviewFilter(agents: {})), ['Agent: none']);
    });
  });
}
