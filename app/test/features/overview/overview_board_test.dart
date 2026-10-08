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
    SessionStatus status = SessionStatus.running,
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
      status: status,
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
    OverviewSubSessionMode subSessions = OverviewSubSessionMode.inside,
  }) => buildOverviewBoard(
    g,
    facts: with_ ?? facts(),
    filter: filter,
    groupBy: groupBy,
    startOfToday: startOfToday,
    memo: memo ?? BoardOrderMemo(),
    subSessions: subSessions,
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

    test('a detached child is a card of its own, and its parent is held out '
        'of Done no more', () {
      final linked = build(
        groups({
          AgentState.ended: [entry('p')],
          AgentState.working: [entry('c', parent: 'p')],
        }),
      ).lanes.single;
      expect(ids(linked, BoardColumn.working), ['p']);

      // Detached: the server cleared the row's parent, and nothing else.
      final detached = build(
        groups({
          AgentState.ended: [entry('p')],
          AgentState.working: [entry('c')],
        }),
      ).lanes.single;
      expect(ids(detached, BoardColumn.working), ['c']);
      final child = detached.cards(BoardColumn.working).single;
      expect(child.parentId, isNull);
      expect(child.breadcrumb, isNull);
      expect(ids(detached, BoardColumn.done), contains('p'));
      final parent = detached
          .cards(BoardColumn.done)
          .firstWhere((card) => card.id == 'p');
      expect(parent.waitingOn, isNull);
      expect(parent.children, isNull);
    });

    test('an attached session nests under its new parent', () {
      final apart = build(
        groups({
          AgentState.ready: [entry('p')],
          AgentState.working: [entry('c')],
        }),
      ).lanes.single;
      expect(ids(apart, BoardColumn.working), ['c']);

      // Attached: the server set the row's parent, and nothing else.
      final board = build(
        groups({
          AgentState.ready: [entry('p')],
          AgentState.working: [entry('c', parent: 'p')],
        }),
      );
      final cards = [
        for (final column in BoardColumn.values)
          ...board.lanes.single.cards(column),
      ];
      expect(cards.map((card) => card.id), ['p']);
      expect(cards.single.children!.total, 1);
      expect(board.children['p']!.map((card) => card.id), ['c']);
    });

    test('an ended parent whose child works stays at work, carrying it', () {
      // Round 56: a parent is not done while its sub-sessions work.
      final board = build(
        groups({
          AgentState.ended: [entry('p')],
          AgentState.working: [entry('c', parent: 'p')],
        }),
      );
      final working = board.lanes.single.cards(BoardColumn.working).single;
      expect(working.entry.id, 'p');
      expect(working.waitingOn, 1);
      expect(working.children!.working, 1);
    });
  });

  group('a parent while its sub-sessions work', () {
    for (final mode in OverviewSubSessionMode.values) {
      group(mode.label, () {
        OverviewBoard of(Map<AgentState, List<WorkspaceSessionEntry>> by) =>
            build(groups(by), subSessions: mode);

        test('a ready parent with a working child is at work, waiting on '
            'it', () {
          final lane = of({
            AgentState.ready: [entry('p')],
            AgentState.working: [entry('c', parent: 'p')],
          }).lanes.single;
          expect(ids(lane, BoardColumn.working).first, 'p');
          expect(ids(lane, BoardColumn.ready), isEmpty);
          final parent = lane.cards(BoardColumn.working).first;
          expect(parent.waitingOn, 1);
        });

        test('a child that needs you puts its parent in the waiting state '
            'too', () {
          final lane = of({
            AgentState.ready: [entry('p')],
            AgentState.needsYou: [entry('c', parent: 'p')],
          }).lanes.single;
          expect(ids(lane, BoardColumn.needsYou), contains('p'));
          expect(ids(lane, BoardColumn.ready), isEmpty);
        });

        test('a grandchild at work holds the top parent too', () {
          final lane = of({
            AgentState.ended: [entry('p'), entry('c', parent: 'p')],
            AgentState.working: [entry('g', parent: 'c')],
          }).lanes.single;
          expect(ids(lane, BoardColumn.working).first, 'p');
          expect(ids(lane, BoardColumn.done), isNot(contains('p')));
        });

        test('only once every child is done or ended does it go to Done', () {
          final lane = of({
            AgentState.ended: [entry('p'), entry('c1', parent: 'p')],
            AgentState.ready: [entry('c2', parent: 'p')],
          }).lanes.single;
          expect(ids(lane, BoardColumn.done), contains('p'));
          expect(ids(lane, BoardColumn.working), isEmpty);
          final parent = lane
              .cards(BoardColumn.done)
              .firstWhere((c) => c.id == 'p');
          expect(parent.waitingOn, isNull);
        });

        test('a parent at work on its own is not said to wait', () {
          final lane = of({
            AgentState.working: [entry('p'), entry('c', parent: 'p')],
          }).lanes.single;
          expect(lane.cards(BoardColumn.working).first.waitingOn, isNull);
        });
      });
    }
  });

  group('a sub-session an agent just started', () {
    // Its row says `created` and nothing has reported a status yet, which
    // the lens reads as ready: it sat in "Done · ready to close", or folded
    // into a ready parent's card that drew no sub-sessions.
    List<AgentStateGroup> justStarted() => groups({
      AgentState.working: [entry('p')],
      AgentState.ready: [
        entry('c', parent: 'p', status: SessionStatus.created),
      ],
    });

    test('as cards: an "At work" card, starting', () {
      final board = build(
        justStarted(),
        subSessions: OverviewSubSessionMode.cards,
      );
      final lane = board.lanes.single;
      expect(ids(lane, BoardColumn.working), ['p', 'c']);
      expect(ids(lane, BoardColumn.ready), isEmpty);
      final child = lane.cards(BoardColumn.working).last;
      expect(overviewIsStarting(child), isTrue);
      expect(
        overviewIsStarting(lane.cards(BoardColumn.working).first),
        isFalse,
      );
    });

    test('inside: on its parent\'s card, counted as working', () {
      final board = build(justStarted());
      final parent = board.lanes.single.cards(BoardColumn.working).single;
      expect(parent.children!.working, 1);
      expect(board.children['p']!.single.state, AgentState.working);
    });

    test('once it reports, its own state stands', () {
      final board = build(
        groups({
          AgentState.working: [entry('p')],
          AgentState.ready: [entry('c', parent: 'p')],
        }),
        subSessions: OverviewSubSessionMode.cards,
      );
      expect(ids(board.lanes.single, BoardColumn.ready), ['c']);
    });
  });

  group('sub-sessions as cards', () {
    test('each child is a card of its own, right after its parent, which '
        'it names', () {
      final board = build(
        groups({
          AgentState.working: [
            entry('p', age: const Duration(minutes: 10)),
            entry('x', age: const Duration(minutes: 5)),
            entry('c1', parent: 'p'),
            entry('g', parent: 'c1', age: const Duration(minutes: 1)),
          ],
        }),
        subSessions: OverviewSubSessionMode.cards,
      );
      final working = board.lanes.single.cards(BoardColumn.working);
      // Newest first is c1, g, x, p; each child follows its parent instead.
      expect([for (final c in working) c.id], ['x', 'p', 'c1', 'g']);
      final c1 = working.firstWhere((c) => c.id == 'c1');
      expect(c1.parentId, 'p');
      expect(c1.breadcrumb, 'T p');
      expect(working.firstWhere((c) => c.id == 'g').parentId, 'c1');
      expect(working.firstWhere((c) => c.id == 'p').children, isNull);
    });

    test('a child in another state keeps its own column, once', () {
      final board = build(
        groups({
          AgentState.working: [entry('p')],
          AgentState.needsYou: [entry('c', parent: 'p')],
          AgentState.ready: [entry('r', parent: 'p')],
        }),
        subSessions: OverviewSubSessionMode.cards,
      );
      final lane = board.lanes.single;
      expect(ids(lane, BoardColumn.needsYou), ['c']);
      expect(ids(lane, BoardColumn.ready), ['r']);
      expect(ids(lane, BoardColumn.working), ['p']);
    });

    test('the dashboard\'s own order keeps a child after its parent', () {
      final cards = build(
        groups({
          AgentState.working: [
            entry('p', age: const Duration(minutes: 10)),
            entry('c', parent: 'p'),
            entry('q', age: const Duration(minutes: 3)),
          ],
        }),
        subSessions: OverviewSubSessionMode.cards,
      ).lanes.single.cards(BoardColumn.working);
      final reordered = byUrgency(cards.reversed.toList());
      expect(
        [for (final c in nestUnderParents(reordered)) c.id].join(),
        anyOf('pcq', 'qpc'),
      );
    });

    test('inside their parent, the default, children stack as before', () {
      final board = build(
        groups({
          AgentState.working: [entry('p'), entry('c', parent: 'p')],
        }),
      );
      final working = board.lanes.single.cards(BoardColumn.working);
      expect([for (final c in working) c.id], ['p']);
      expect(working.single.children!.total, 1);
      expect(board.children['p']!.single.id, 'c');
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

    group('by context', () {
      // p1 and p2 in two contexts, p3 in none, p4 in one since deleted.
      const contextOfProject = {'p1': 'c-apps', 'p2': 'c-web', 'p4': 'c-gone'};
      final byContext = OverviewFacts(
        projectOf: (e) => {'a': 'p1', 'b': 'p2', 'c': 'p3', 'd': 'p4'}[e.id],
        contextOf: (e) =>
            contextOfProject[{
              'a': 'p1',
              'b': 'p2',
              'c': 'p3',
              'd': 'p4',
            }[e.id]],
        machineOf: (e) => e.directory?.environmentId,
        agentOf: (_) => 'claude-code',
        projects: const [],
        machines: const [],
        contexts: const [
          OverviewLaneKey('c-apps', 'Apps'),
          OverviewLaneKey('c-web', 'Web'),
        ],
      );

      test('a lane per context in order, then "No context" last', () {
        final board = build(
          groups({
            AgentState.working: [entry('b'), entry('c'), entry('a')],
            AgentState.ready: [entry('d')],
          }),
          with_: byContext,
          groupBy: OverviewGroupBy.context,
        );
        expect(board.lanes.map((l) => l.label), [
          'Apps',
          'Web',
          kOverviewNoContextLabel,
        ]);
        expect(ids(board.lanes[0], BoardColumn.working), ['a']);
        expect(ids(board.lanes[1], BoardColumn.working), ['b']);
        // No context, and a context that no longer exists, go last.
        expect(ids(board.lanes[2], BoardColumn.working), ['c']);
        expect(ids(board.lanes[2], BoardColumn.ready), ['d']);
      });

      test('"No context" is not drawn when every session has one', () {
        final board = build(
          groups({
            AgentState.working: [entry('a'), entry('b')],
          }),
          with_: byContext,
          groupBy: OverviewGroupBy.context,
        );
        expect(board.lanes.map((l) => l.label), ['Apps', 'Web']);
      });

      test('Context falls back to Project when no context is left', () {
        expect(
          effectiveGroupBy(OverviewGroupBy.context, byContext),
          OverviewGroupBy.context,
        );
        expect(
          effectiveGroupBy(OverviewGroupBy.context, facts()),
          OverviewGroupBy.project,
        );
        expect(
          effectiveGroupBy(OverviewGroupBy.machine, facts()),
          OverviewGroupBy.machine,
        );
      });
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
