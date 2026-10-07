import 'package:agent_cli/process.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/explorer/application/agent_states.dart';
import 'package:karmashala/src/features/explorer/application/workspace_session_entry.dart';
import 'package:karmashala/src/features/overview/application/overview_board.dart';
import 'package:karmashala/src/features/overview/application/overview_tiles.dart';
import 'package:karmashala_session/session.dart';

/// **The Overview's model**: how the counters filter, how the arrows move
/// between cards, which card an id names, and the active-filter chips.
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

  test('an id names its card, a sub-session stacked on its parent too', () {
    final board = build({
      AgentState.working: [entry('parent'), entry('child', parent: 'parent')],
    });
    expect(overviewCardOf(board, 'parent')?.children?.total, 1);
    expect(overviewCardOf(board, 'child')?.entry.id, 'child');
    expect(board.children['parent']?.single.id, 'child');
    expect(overviewCardOf(board, 'nobody'), isNull);
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
