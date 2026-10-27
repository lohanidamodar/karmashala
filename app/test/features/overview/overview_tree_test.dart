import 'dart:async';
import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/explorer/application/agent_states.dart';
import 'package:karmashala/src/features/explorer/application/workspace_session_entry.dart';
import 'package:karmashala/src/features/overview/application/overview_batch.dart';
import 'package:karmashala/src/features/overview/application/overview_board.dart';
import 'package:karmashala/src/features/overview/application/overview_links.dart';
import 'package:karmashala/src/features/overview/application/overview_prefs.dart';
import 'package:karmashala/src/features/overview/application/overview_providers.dart';
import 'package:karmashala/src/features/overview/application/overview_quick_message.dart';
import 'package:karmashala/src/features/overview/application/overview_tree.dart';
import 'package:karmashala/src/features/overview/presentation/overview_end_button.dart'
    show OverviewHoverScope;
import 'package:karmashala/src/features/overview/presentation/overview_hybrid.dart'
    show OverviewSections, overviewSectionsOf;
import 'package:karmashala/src/features/overview/presentation/session_avatar.dart';
import 'package:karmashala/src/features/pipelines/application/pipelines_controller.dart';
import 'package:karmashala_automations/pipelines.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/tokens.dart';

import 'mission_fixture.dart';

MissionSession _s(
  String id,
  String title,
  AgentState state, {
  String? parent,
  String project = 'p-ks',
  String machine = 'windows',
  Duration age = const Duration(minutes: 4),
}) => (
  id: id,
  title: title,
  project: project,
  machine: machine,
  agent: AgentIds.claudeCode,
  state: state,
  age: age,
  parent: parent,
  report: null,
);

/// The realistic board, plus a sub-session of a sub-session (depth 2), a
/// sub-session that waits on you, one filed under another project (another
/// lane), and a session detached from its parent (no parent left).
MissionFixture _fixture() => MissionFixture(
  sessions: [
    ...MissionFixture.realisticSessions(),
    _s(
      'ks-r32-sub0-a',
      'Nested check',
      AgentState.working,
      parent: 'ks-r32-sub0',
    ),
    _s('ks-r32-ask', 'Subagent asks', AgentState.needsYou, parent: 'ks-r32'),
    _s(
      'beej-for-r32',
      'Port it to beej',
      AgentState.working,
      parent: 'ks-r32',
      project: 'p-beej',
    ),
    _s('ks-detached', 'Detached helper', AgentState.working),
  ],
  answers: MissionFixture.realisticAnswers(),
  glances: MissionFixture.realisticGlances(),
);

class _Runs extends PipelinesController {
  @override
  PipelinesState build() => PipelinesState(
    loaded: true,
    runs: {
      'run-1': PipelineRun(
        id: 'run-1',
        definition: kPipelineTemplates.first,
        repositoryId: 'r-p-ks',
        input: 'x',
        state: PipelineRunState.running,
        createdAt: MissionFixture.now,
        updatedAt: MissionFixture.now,
        records: const [
          PipelineStageRecord(
            stageIndex: 0,
            role: 'Plan',
            attempt: 1,
            state: PipelineStageState.running,
            sessionId: 'ks-r32-sub1',
          ),
        ],
      ),
    },
  );
}

/// Keeps what is sent from the board, and sends it at once — or, while
/// [hold] is set, once it completes.
class _SpyMessage extends OverviewQuickMessage {
  _SpyMessage(super.ref);

  final sent = <(String, String)>[];
  Completer<void>? hold;

  @override
  Future<QuickMessageSent> send(
    String sessionId,
    String text, {
    String? requestId,
  }) async {
    sent.add((sessionId, text));
    await hold?.future;
    return QuickMessageSent(requestId: requestId ?? 'key-${sent.length}');
  }
}

OverviewCard _card(
  String id,
  AgentState state, {
  String? parent,
  int? waitingOn,
  int at = 0,
}) => OverviewCard(
  entry: WorkspaceSessionEntry(
    id: id,
    title: 'T $id',
    createdAt: MissionFixture.now.add(Duration(minutes: at)),
  ),
  state: state,
  parentId: parent,
  waitingOn: waitingOn,
);

/// A board of one lane per key of [lanes], each card in its own state's
/// column.
OverviewBoard _board(Map<String, List<OverviewCard>> lanes) => OverviewBoard(
  lanes: [
    for (final MapEntry(key: key, value: cards) in lanes.entries)
      OverviewLane(
        key: key,
        label: key,
        live: {
          for (final column in const [
            BoardColumn.needsYou,
            BoardColumn.working,
            BoardColumn.ready,
          ])
            column: [
              for (final card in cards)
                if (card.column == column) card,
            ],
        },
        doneToday: [
          for (final card in cards)
            if (card.column == BoardColumn.done) card,
        ],
        doneOlder: const [],
      ),
  ],
  states: const {},
);

String _shape(OverviewTreeNode node) => node.children.isEmpty
    ? node.card.id
    : '${node.card.id}(${node.children.map(_shape).join(' ')})';

/// **The dashboard's session tree**: a family is one fixed-slot card — the
/// parent's avatar inside it, its sub-sessions branching off a stem in spawn
/// order, theirs nested a level further — each opening the peek, folding to
/// its root, lit together under a pointer, and a child drawn apart from its
/// parent a jump away.
void main() {
  OverviewSections sectionsOf(OverviewBoard board) => overviewSectionsOf(
    board,
    overviewForestOf(board),
    waitingSince: (_) => null,
  );

  group('the forest', () {
    List<String> shapes(OverviewForest forest, [String lane = 'ks']) => [
      for (final (l, trees) in forest.lanes)
        if (l.key == lane) ...trees.map(_shape),
    ];

    test('a root, its branches and their nesting, each family once; '
        'sub-sessions in the order they were started', () {
      final board = _board({
        'ks': [
          _card('p', AgentState.working),
          _card('c', AgentState.working, parent: 'p', at: 1),
          _card('g', AgentState.ready, parent: 'c', at: 2),
          _card('d', AgentState.ended, parent: 'p', at: 3),
          _card('ask', AgentState.needsYou, parent: 'p', at: 4),
          _card('other', AgentState.working, at: 5),
          _card('stray', AgentState.working, parent: 'gone', at: 6),
        ],
      });
      final forest = overviewForestOf(board);
      expect(shapes(forest), ['p(c(g) d ask)', 'other', 'stray']);
      expect(forest.placed, {'p', 'c', 'g', 'd', 'ask', 'other', 'stray'});
      final p = forest.lanes.single.$2.first;
      expect([for (final c in p.descendants) c.id], ['c', 'g', 'd', 'ask']);
    });

    test('a change of state moves no family and no sub-session', () {
      List<OverviewCard> cards(List<AgentState> s) => [
        _card('a', s[0]),
        _card('a1', s[1], parent: 'a', at: 1),
        _card('a2', s[2], parent: 'a', at: 2),
        _card('b', s[3], at: 3),
        _card('c', s[4], at: 4),
      ];
      const w = AgentState.working, r = AgentState.ready;
      const n = AgentState.needsYou, e = AgentState.ended;
      final before = shapes(
        overviewForestOf(
          _board({
            'ks': cards([w, w, r, r, n]),
          }),
        ),
      );
      for (final after in [
        [r, n, w, w, w],
        [n, r, w, e, r],
        [w, e, n, n, e],
      ]) {
        expect(
          shapes(overviewForestOf(_board({'ks': cards(after)}))),
          before,
          reason: '$after',
        );
      }
      expect(before, ['a(a1 a2)', 'b', 'c']);
    });

    test('a ready family and one that ended today stay in their lane', () {
      final board = _board({
        'ks': [
          _card('solo', AgentState.ready),
          _card('r', AgentState.ready, at: 1),
          _card('rc', AgentState.ended, parent: 'r', at: 2),
          _card('gone', AgentState.ended, at: 3),
        ],
      });
      expect(shapes(overviewForestOf(board)), ['solo', 'r(rc)', 'gone']);
    });

    test('pinned families first, then the hand order, then the rest by when '
        'they started', () {
      final board = _board({
        'ks': [
          for (final (i, id) in ['a', 'b', 'c', 'd', 'e'].indexed)
            _card(id, AgentState.working, at: i),
        ],
      });
      expect(shapes(overviewForestOf(board)), ['a', 'b', 'c', 'd', 'e']);
      final forest = overviewForestOf(
        board,
        order: {
          'ks': ['c', 'a', 'gone'],
        },
        pinned: {'e'},
      );
      expect(shapes(forest), ['e', 'c', 'a', 'b', 'd']);
    });

    test('a parent held by a sub-session that waits on you roots its family; '
        'the sub-session alone waits in the queue', () {
      final held = _card('p', AgentState.needsYou, waitingOn: 1);
      expect(held.heldBySubSessions, isTrue);
      final board = _board({
        'ks': [held, _card('c', AgentState.needsYou, parent: 'p', at: 1)],
      });
      final forest = overviewForestOf(board);
      expect(shapes(forest), ['p(c)']);
      expect(sectionsOf(board).queue.map((c) => c.id), ['c']);
    });

    test('a child in another lane is a root there, never split into its '
        'parent\'s', () {
      final board = _board({
        'ks': [_card('p', AgentState.working)],
        'beej': [_card('c', AgentState.working, parent: 'p')],
      });
      final forest = overviewForestOf(board);
      expect(shapes(forest), ['p']);
      expect(shapes(forest, 'beej'), ['c']);
    });

    test('a parent that ended keeps its children under it, drawn once', () {
      final board = _board({
        'ks': [
          _card('p', AgentState.ended),
          _card('c', AgentState.working, parent: 'p', at: 1),
          _card('d', AgentState.ended, parent: 'p', at: 2),
        ],
      });
      final forest = overviewForestOf(board);
      expect(shapes(forest), ['p(c d)']);
      expect(forest.placed, {'p', 'c', 'd'});
      expect(sectionsOf(board).families.map((c) => c.id), ['p', 'c', 'd']);
    });

    test('a parent that ended before today heads its family only while a '
        'session below it is shown', () {
      OverviewBoard board(List<OverviewCard> live) => OverviewBoard(
        lanes: [
          OverviewLane(
            key: 'ks',
            label: 'ks',
            live: {
              BoardColumn.needsYou: const [],
              BoardColumn.working: live,
              BoardColumn.ready: const [],
            },
            doneToday: const [],
            doneOlder: [
              _card('old', AgentState.ended),
              _card('lone', AgentState.ended, at: 1),
            ],
          ),
        ],
        states: const {},
      );
      expect(
        shapes(
          overviewForestOf(
            board([_card('c', AgentState.working, parent: 'old', at: 2)]),
          ),
        ),
        ['old(c)'],
      );
      expect(overviewForestOf(board(const [])).lanes, isEmpty);
    });

    test('a cycle of parents through a stopped session is drawn, once', () {
      final board = _board({
        'ks': [
          _card('a', AgentState.ended, parent: 'b'),
          _card('b', AgentState.working, parent: 'a', at: 1),
        ],
      });
      final forest = overviewForestOf(board);
      expect(forest.placed, {'a', 'b'});
      expect(shapes(forest), hasLength(1));
    });

    test('a cycle of stopped parents keeps its working sub-session in one '
        'family, whatever the order', () {
      final waits = AgentState.values.firstWhere(
        (s) => columnOf(s) == BoardColumn.needsYou,
      );
      for (final kid in [null, waits]) {
        final cards = [
          _card('c', AgentState.working, parent: 'a'),
          if (kid != null) _card('d', kid, parent: 'c'),
          _card('a', AgentState.ended, parent: 'b'),
          _card('b', AgentState.ended, parent: 'a'),
        ];
        final ids = {for (final card in cards) card.id};
        for (final order in [cards, cards.reversed.toList()]) {
          final forest = overviewForestOf(_board({'ks': order}));
          final trees = [for (final (_, trees) in forest.lanes) ...trees];
          expect(trees, hasLength(1), reason: '$kid, ${order.first.id}');
          expect(
            trees.single.drawn.map((c) => c.id).toSet(),
            ids,
            reason: '$kid, ${order.first.id}',
          );
        }
      }
    });

    test('a fold keeps only the root drawn', () {
      final tree = overviewForestOf(
        _board({
          'ks': [
            _card('p', AgentState.working),
            _card('c', AgentState.working, parent: 'p'),
            _card('g', AgentState.working, parent: 'c'),
          ],
        }),
      ).lanes.single.$2.single;
      expect(overviewDrawnOf(tree, {}).map((c) => c.id), ['p', 'c', 'g']);
      expect(overviewDrawnOf(tree, {'p'}).map((c) => c.id), ['p']);
      // Any node folds: only what is below it goes.
      expect(overviewDrawnOf(tree, {'c'}).map((c) => c.id), ['p', 'c']);
    });

    test('a fold says what it hides, and what of it needs you', () {
      final below = [
        _card('a', AgentState.ready, parent: 'p'),
        _card('b', AgentState.needsYou, parent: 'p'),
        _card('c', AgentState.working, parent: 'p'),
      ];
      expect(
        overviewFoldedSummary(below),
        '3 sub-sessions · 1 of 3 done · 1 needs you · 1 working',
      );
      expect(overviewFoldedLine(below), '3 sub-sessions · 1 needs you');
      expect(overviewFoldedLine(below.take(1).toList()), '1 sub-session');
    });

    test('a family is summed up, its share done and what waits counted', () {
      final tree = overviewForestOf(
        _board({
          'ks': [
            _card('p', AgentState.working),
            _card('a', AgentState.ready, parent: 'p'),
            _card('b', AgentState.ended, parent: 'p'),
            _card('c', AgentState.working, parent: 'p'),
            _card('d', AgentState.needsYou, parent: 'p'),
          ],
        }),
      ).lanes.single.$2.single;
      expect(
        overviewFamilySummary(tree.descendants),
        '2 of 4 done · 1 needs you · 1 working',
      );
      expect(overviewDoneShare(tree), 0.5);
      expect(overviewWaitingIn(tree), 1);
      expect(overviewDoneShare(tree.children.last), isNull);
    });

    test('a family lights up together, and only the family', () {
      final parent = _card('p', AgentState.working);
      final child = _card('c', AgentState.working, parent: 'p');
      final other = _card('o', AgentState.working);
      final onChild = OverviewLinkFocus(child.id, child.parentId);
      final onParent = OverviewLinkFocus(parent.id, null);
      expect(overviewLinkLit(parent, onChild), isTrue);
      expect(overviewLinkLit(child, onParent), isTrue);
      expect(overviewLinkLit(other, onParent), isFalse);
      expect(overviewLinkLit(child, onChild), isFalse);
    });
  });

  group('the prefs', () {
    test('a file from before the tree, with its sub-session layout, still '
        'loads, and the layout is no longer kept', () {
      final prefs = OverviewPrefs.fromJson({
        'groupBy': 'machine',
        'view': 'board',
        'subSessions': 'cards',
        'pinned': ['a'],
        'launchInBackground': false,
      });
      expect(prefs.groupBy, OverviewGroupBy.machine);
      expect(prefs.pinned, ['a']);
      expect(prefs.launchInBackground, isFalse);
      expect(prefs.toJson().containsKey('subSessions'), isFalse);
      expect(
        OverviewPrefs.fromJson({'subSessions': 'inside'}).groupBy,
        OverviewGroupBy.project,
      );
    });
  });

  group('the avatar', () {
    test('two letters from the title', () {
      expect(sessionInitials('analytics'), 'An');
      expect(sessionInitials('Round 32 · Overview redesign'), 'R3');
      expect(sessionInitials('tipot Windows build'), 'TW');
      expect(sessionInitials('—'), '·');
    });

    Future<void> avatar(
      WidgetTester tester,
      OverviewCard card, {
      double? progress,
      int waiting = 0,
    }) => tester.pumpWidget(
      ProviderScope(
        overrides: [
          overviewFactsProvider.overrideWithValue(
            OverviewFacts(
              projectOf: (_) => null,
              machineOf: (_) => null,
              agentOf: (_) => null,
              projects: const [],
              machines: const [],
            ),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: Center(
            child: SessionAvatar(
              card: card,
              size: Chrome.sessionAvatar,
              progress: progress,
              waiting: waiting,
            ),
          ),
        ),
      ),
    );

    SessionRingPainter ring(WidgetTester tester, AgentState state) =>
        tester
                .widget<CustomPaint>(
                  find.byKey(ValueKey('session-avatar-ring:${state.name}')),
                )
                .painter!
            as SessionRingPainter;

    testWidgets('each state its own ring; working an arc', (tester) async {
      for (final state in AgentState.values) {
        await avatar(tester, _card('s', state));
        final context = tester.element(find.byType(SessionAvatar));
        if (state == AgentState.working) {
          expect(
            find.byKey(const ValueKey('session-avatar-arc')),
            findsOneWidget,
          );
          continue;
        }
        final painter = ring(tester, state);
        expect(painter.progress, isNull, reason: state.name);
        expect(
          painter.color,
          sessionRingColor(context, state),
          reason: state.name,
        );
        expect(
          find.byKey(const ValueKey('session-avatar-face:s')),
          findsOneWidget,
        );
      }
      final semantic = SemanticColors.of(
        tester.element(find.byType(SessionAvatar)),
      );
      await avatar(tester, _card('s', AgentState.needsYou));
      expect(ring(tester, AgentState.needsYou).color, semantic.attention);
      await avatar(tester, _card('s', AgentState.failed));
      expect(ring(tester, AgentState.failed).color, semantic.failure);
      await avatar(tester, _card('s', AgentState.ready));
      expect(ring(tester, AgentState.ready).color, semantic.idle);
    });

    testWidgets('a parent\'s ring fills with its share done, even at work', (
      tester,
    ) async {
      await avatar(tester, _card('p', AgentState.working), progress: 0.6);
      expect(find.byKey(const ValueKey('session-avatar-arc')), findsNothing);
      expect(ring(tester, AgentState.working).progress, 0.6);
    });

    testWidgets('what waits on you is counted at its corner, and said', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await avatar(tester, _card('s', AgentState.needsYou), waiting: 3);
      final badge = find.byKey(const ValueKey('session-avatar-badge:s'));
      expect(
        find.descendant(of: badge, matching: find.text('3')),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel('T s, Needs you, 3 waiting on you'),
        findsOneWidget,
      );
      await avatar(tester, _card('s', AgentState.ready));
      expect(badge, findsNothing);
      semantics.dispose();
    });
  });

  group('on the board', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('ks-tree');
    });
    tearDown(() async {
      try {
        await dir.delete(recursive: true);
      } on FileSystemException {
        // Windows may still hold the file; the OS sweeps temp.
      }
    });

    Future<ProviderContainer> pump(
      WidgetTester tester, {
      Size size = const Size(1440, 1400),
      double textScale = 1,
      bool pipeline = false,
      bool? phone,
      MissionFixture? fixture,
    }) => pumpMission(
      tester,
      fixture: fixture ?? _fixture(),
      prefsDir: dir,
      size: size,
      phone: phone ?? size.width < 600,
      textScale: textScale,
      overrides: [
        if (pipeline) pipelinesProvider.overrideWith(_Runs.new),
        overviewQuickMessageProvider.overrideWith(_SpyMessage.new),
      ],
    );

    List<(String, String)> sent(ProviderContainer c) =>
        (c.read(overviewQuickMessageProvider) as _SpyMessage).sent;

    Future<void> reveal(
      WidgetTester tester,
      Finder finder, {
      double delta = 200,
    }) async {
      await tester.scrollUntilVisible(finder, delta, scrollable: hybridList);
      await tester.ensureVisible(finder);
      await settleMission(tester);
    }

    Finder pill(String id) => find.byKey(ValueKey('overview-tree-pill:$id'));

    // Round 32's family has seven sub-sessions drawn: past four, the rest
    // fold into one row until it is tapped.
    Future<void> showAll(WidgetTester tester, [String id = 'ks-r32']) async {
      final more = find.byKey(ValueKey('overview-tree-more:$id'));
      await reveal(tester, more);
      await tester.tap(more);
      await settleMission(tester);
    }

    testWidgets('a sub-session says where it runs only where that differs '
        'from its parent, on a phone at large text too', (tester) async {
      final base = _fixture();
      for (final (size, scale) in const [
        (Size(1440, 1400), 1.0),
        (Size(360, 800), 1.6),
      ]) {
        await pump(
          tester,
          size: size,
          textScale: scale,
          fixture: MissionFixture(
            sessions: [
              ...base.sessions,
              _s(
                'ks-r32-wsl',
                'Linux check',
                AgentState.working,
                parent: 'ks-r32',
                machine: 'wsl:arch',
              ),
            ],
            answers: base.answers,
            glances: base.glances,
          ),
        );
        await showAll(tester);
        final apart = find.byKey(
          const ValueKey('overview-tree-place:ks-r32-wsl'),
        );
        await reveal(tester, apart);
        // The machine alone: the project is its parent's.
        expect(tester.widget<Text>(apart).data, 'WSL · arch');
        // Where it is its parent's, nothing is said.
        expect(
          find.byKey(const ValueKey('overview-tree-place:ks-r32-sub0')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('overview-tree-place:ks-r32-ask')),
          findsNothing,
        );
        expect(tester.takeException(), isNull, reason: '$size at $scale');
        await unmountMission(tester);
      }
    });

    testWidgets('a family is one card: the parent\'s avatar inside it, its '
        'sub-sessions on branches, and theirs nested a level further', (
      tester,
    ) async {
      await pump(tester);
      final family = familyCard('ks-r32');
      await reveal(tester, family);
      await showAll(tester);
      Finder inFamily(Finder f) => find.descendant(of: family, matching: f);
      final head = find.byKey(const ValueKey('overview-family-head:ks-r32'));
      expect(inFamily(head), findsOneWidget);
      expect(
        inFamily(find.byKey(const ValueKey('session-avatar:ks-r32'))),
        findsOneWidget,
      );
      for (final id in ['ks-r32-sub0', 'ks-r32-sub0-a', 'ks-r32-ask']) {
        expect(inFamily(pill(id)), findsOneWidget, reason: id);
      }
      // Nested: on the branch of its own parent.
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('overview-tree-branch:ks-r32-sub0')),
          matching: pill('ks-r32-sub0-a'),
        ),
        findsOneWidget,
      );
      // The parent's avatar sits inside the card at its top left, the header
      // beside it; a branch's avatar is smaller and to the right of the stem.
      final root = tester.getRect(
        find.byKey(const ValueKey('session-avatar:ks-r32')),
      );
      final card = tester.getRect(family);
      expect(root.size, const Size.square(Chrome.sessionAvatar));
      expect(card.contains(root.topLeft), isTrue);
      expect(tester.getRect(head).left, greaterThan(root.right));
      final kid = tester.getRect(
        find.byKey(const ValueKey('session-avatar:ks-r32-sub0')),
      );
      expect(kid.size, const Size.square(Chrome.subSessionAvatar));
      expect(kid.left, greaterThan(root.center.dx));
      final nested = tester.getRect(
        find.byKey(const ValueKey('session-avatar:ks-r32-sub0-a')),
      );
      expect(nested.left, greaterThan(kid.center.dx));
      // A session on its own is a root with no branches.
      final solo = familyCard('ks-release');
      await reveal(tester, solo);
      expect(
        find.descendant(
          of: solo,
          matching: find.byWidgetPredicate(
            (w) =>
                w.key is ValueKey<String> &&
                (w.key! as ValueKey<String>).value.startsWith(
                  'overview-tree-pill:',
                ),
          ),
        ),
        findsNothing,
      );
      await unmountMission(tester);
    });

    testWidgets('past four rows the rest fold into one that counts them, '
        'and opens them all', (tester) async {
      await pump(tester);
      final more = find.byKey(const ValueKey('overview-tree-more:ks-r32'));
      await reveal(tester, more);
      // In spawn order: the four oldest are drawn.
      for (final id in ['ks-r32-sub4', 'ks-r32-sub3', 'ks-r32-ask']) {
        expect(pill(id), findsOneWidget, reason: id);
      }
      expect(pill('ks-r32-sub0'), findsNothing);
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('overview-tree-more-line:ks-r32')),
            )
            .data,
        '3 more',
      );
      await tester.tap(more);
      await settleMission(tester);
      expect(pill('ks-r32-sub0'), findsOneWidget);
      expect(pill('ks-r32-sub0-a'), findsOneWidget);
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('overview-tree-more-line:ks-r32')),
            )
            .data,
        'Show fewer',
      );
      await tester.tap(more);
      await settleMission(tester);
      expect(pill('ks-r32-sub0'), findsNothing);
      await unmountMission(tester);
    });

    testWidgets('a pill opens the peek; its menu hands it back to its parent', (
      tester,
    ) async {
      final c = await pump(tester);
      const id = 'ks-r32-sub2';
      await reveal(tester, pill(id));
      // Ready under a parent on the board: its menu hands it back.
      await tester.tap(pill(id), buttons: kSecondaryButton);
      await settleMission(tester);
      expect(
        find.byKey(const ValueKey('overview-card-menu:hand-back')),
        findsOneWidget,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settleMission(tester);
      expect(c.read(overviewFocusProvider).peeked, isNull);
      await tester.tap(pill(id));
      await settleMission(tester);
      expect(c.read(overviewFocusProvider).peeked, id);
      await unmountMission(tester);
    });

    testWidgets('a pill takes the keys: Enter and Space open the peek', (
      tester,
    ) async {
      final c = await pump(tester);
      const id = 'ks-r32-sub3';
      Future<void> press(LogicalKeyboardKey key) async {
        await reveal(tester, pill(id));
        // The pill's own focus: the nearest one above what it draws.
        Focus.of(
          tester.element(
            find
                .descendant(
                  of: pill(id),
                  matching: find.byType(OverviewHoverScope),
                )
                .first,
          ),
        ).requestFocus();
        await settleMission(tester);
        await tester.sendKeyEvent(key);
        await settleMission(tester);
      }

      await press(LogicalKeyboardKey.enter);
      expect(c.read(overviewFocusProvider).peeked, id);
      c.read(overviewFocusProvider.notifier).closePeek();
      await settleMission(tester);
      await press(LogicalKeyboardKey.space);
      expect(c.read(overviewFocusProvider).peeked, id);
      await unmountMission(tester);
    });

    Finder knob(String id) => find.byKey(ValueKey('overview-tree-knob:$id'));

    testWidgets('the header counts what finished; a fold keeps only the '
        'root, and what waits stays answerable in the drawer', (tester) async {
      final c = await pump(tester);
      final meta = find.byKey(const ValueKey('overview-family-meta:ks-r32'));
      await reveal(tester, meta);
      expect(tester.widget<Text>(meta).data, startsWith('3/7 finished'));
      await reveal(tester, knob('ks-r32'));
      await tester.tap(knob('ks-r32'));
      await settleMission(tester);
      expect(c.read(overviewFoldedParentsProvider), {'ks-r32'});
      expect(pill('ks-r32-sub3'), findsNothing);
      expect(meta, findsOneWidget);
      await openWaiting(tester);
      expect(
        find.byKey(const ValueKey('overview-queue-card:ks-r32-ask')),
        findsOneWidget,
      );
      c.read(overviewFoldedParentsProvider.notifier).toggle('ks-r32');
      await settleMission(tester);
      expect(pill('ks-r32-sub3'), findsOneWidget);
      await unmountMission(tester);
    });

    testWidgets('a knob on the stem folds the family to one row that '
        'still counts what asks, and a tap unfolds it', (tester) async {
      final semantics = tester.ensureSemantics();
      final c = await pump(tester);
      await reveal(tester, knob('ks-r32'));
      expect(
        tester.getSemantics(knob('ks-r32')),
        isSemantics(
          label: 'Fold 7 sub-sessions',
          isButton: true,
          isExpanded: true,
        ),
      );
      SessionAvatar root() => tester.widget<SessionAvatar>(
        find.byWidgetPredicate(
          (w) => w is SessionAvatar && w.card.id == 'ks-r32',
        ),
      );
      final ring = (root().progress, root().waiting);
      await tester.tap(knob('ks-r32'));
      await settleMission(tester);
      expect(c.read(overviewFoldedParentsProvider), {'ks-r32'});
      expect(pill('ks-r32-sub3'), findsNothing);
      final strip = find.byKey(const ValueKey('overview-tree-strip:ks-r32'));
      expect(strip, findsOneWidget);
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('overview-tree-folded-summary:ks-r32')),
            )
            .data,
        '7 sub-sessions · 1 ask',
      );
      expect(
        find.descendant(of: strip, matching: find.text('+3')),
        findsOneWidget,
      );
      expect(
        tester.getSemantics(knob('ks-r32')),
        isSemantics(label: 'Show 7 sub-sessions', isExpanded: false),
      );
      // A fold hides; the ring and the count still hold what it hides.
      expect((root().progress, root().waiting), ring);
      expect(root().waiting, 1);
      await tester.tap(strip);
      await settleMission(tester);
      expect(c.read(overviewFoldedParentsProvider), isEmpty);
      expect(pill('ks-r32-sub3'), findsOneWidget);
      semantics.dispose();
      await unmountMission(tester);
    });

    testWidgets('an inner node folds: its children go, and its pill says '
        'what it hides', (tester) async {
      final c = await pump(tester);
      await showAll(tester);
      await reveal(tester, pill('ks-r32-sub0-a'));
      await reveal(tester, knob('ks-r32-sub0'));
      await tester.tap(knob('ks-r32-sub0'));
      await settleMission(tester);
      expect(c.read(overviewFoldedParentsProvider), {'ks-r32-sub0'});
      expect(pill('ks-r32-sub0-a'), findsNothing);
      expect(pill('ks-r32-sub0'), findsOneWidget);
      expect(pill('ks-r32-sub2'), findsOneWidget, reason: 'siblings stay');
      expect(
        tester
            .widget<Text>(
              find.byKey(
                const ValueKey('overview-tree-folded-line:ks-r32-sub0'),
              ),
            )
            .data,
        '1 sub-session',
      );
      await tester.tap(knob('ks-r32-sub0'));
      await settleMission(tester);
      expect(pill('ks-r32-sub0-a'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('overview-tree-folded-line:ks-r32-sub0')),
        findsNothing,
      );
      await unmountMission(tester);
    });

    testWidgets('a fold that hides a picked node takes it out of the batch '
        'and of the keys\' walk', (tester) async {
      final c = await pump(tester);
      final bar = find.byKey(const ValueKey('overview-batch-bar'));
      c.read(overviewSelectionProvider.notifier).toggle('ks-r32-sub0-a');
      await settleMission(tester);
      expect(bar, findsOneWidget);
      List<String> walked() => [
        for (final card in overviewSectionsOf(
          c.read(overviewBoardProvider),
          overviewForestOf(c.read(overviewBoardProvider)),
          waitingSince: (_) => null,
          folded: c.read(overviewFoldedParentsProvider),
        ).families)
          card.id,
      ];
      expect(walked(), contains('ks-r32-sub0-a'));

      c.read(overviewFoldedParentsProvider.notifier).toggle('ks-r32-sub0');
      await settleMission(tester);
      expect(bar, findsNothing);
      expect(walked(), isNot(contains('ks-r32-sub0-a')));
      expect(walked(), contains('ks-r32-sub0'));

      c.read(overviewFoldedParentsProvider.notifier).toggle('ks-r32-sub0');
      await settleMission(tester);
      expect(bar, findsOneWidget);
      await unmountMission(tester);
    });

    testWidgets('under a thumb a knob is a thumb\'s target', (tester) async {
      await pump(tester, size: const Size(390, 1400));
      await reveal(tester, knob('ks-r32'));
      final size = tester.getSize(knob('ks-r32'));
      expect(size.width, greaterThanOrEqualTo(Touch.target));
      expect(size.height, greaterThanOrEqualTo(Touch.target));
      await unmountMission(tester);
    });

    testWidgets('the batch bar follows a fold: a picked child folded away '
        'leaves it, and comes back with the unfold', (tester) async {
      final c = await pump(tester);
      final bar = find.byKey(const ValueKey('overview-batch-bar'));
      c.read(overviewSelectionProvider.notifier).toggle('ks-r32-sub0');
      await settleMission(tester);
      expect(bar, findsOneWidget);

      // Nothing else changes between: no status, no board.
      c.read(overviewFoldedParentsProvider.notifier).toggle('ks-r32');
      await settleMission(tester);
      expect(bar, findsNothing);

      c.read(overviewFoldedParentsProvider.notifier).toggle('ks-r32');
      await settleMission(tester);
      expect(bar, findsOneWidget);
      await unmountMission(tester);
    });

    testWidgets('a pointer over a pill slides it, lights its avatar and its '
        'family', (tester) async {
      await pump(tester);
      await showAll(tester);
      final parent = find.byKey(const ValueKey('overview-family-head:ks-r32'));
      await reveal(tester, parent);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(parent));
      await settleMission(tester);
      expect(
        find.byKey(const ValueKey('overview-link-lit:ks-r32-sub0')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('overview-link-lit:ks-r32-sub0-a')),
        findsNothing,
        reason: 'a grandchild is its own parent\'s',
      );

      SessionAvatar avatarOf(String id) => tester.widget<SessionAvatar>(
        find.byWidgetPredicate((w) => w is SessionAvatar && w.card.id == id),
      );
      expect(avatarOf('ks-r32-sub0').glow, isFalse);
      await mouse.moveTo(tester.getCenter(pill('ks-r32-sub0')));
      await settleMission(tester);
      expect(avatarOf('ks-r32-sub0').glow, isTrue);
      expect(
        find.byKey(const ValueKey('overview-link-lit:ks-r32')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('overview-link-lit:ks-r32-sub0-a')),
        findsOneWidget,
      );
      await mouse.moveTo(Offset.zero);
      await settleMission(tester);
      expect(avatarOf('ks-r32-sub0').glow, isFalse);
      await unmountMission(tester);
    });

    testWidgets('the pick box takes the avatar\'s face under a pointer and '
        'picks; a click on the pill opens its peek', (tester) async {
      final c = await pump(tester);
      const id = 'ks-r32-sub2';
      await reveal(tester, pill(id));
      final box = find.byKey(const ValueKey('overview-tree-select:$id'));
      expect(box, findsNothing);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(pill(id)));
      await settleMission(tester);
      final avatar = tester.getRect(
        find.byKey(const ValueKey('session-avatar:$id')),
      );
      expect(avatar.contains(tester.getCenter(box)), isTrue);
      expect(avatar.size, const Size.square(Chrome.subSessionAvatar));
      // Over the box itself, the pill is still hovered.
      await mouse.moveTo(tester.getCenter(box));
      await settleMission(tester);
      await tester.tap(box);
      await settleMission(tester);
      expect(c.read(overviewSelectionProvider).contains(id), isTrue);
      expect(
        c.read(overviewFocusProvider).peeked,
        isNull,
        reason: 'picking is not opening',
      );
      await tester.tap(box);
      await settleMission(tester);
      expect(c.read(overviewSelectionProvider).isEmpty, isTrue);

      await mouse.moveTo(tester.getCenter(pill(id)));
      await settleMission(tester);
      await tester.tap(pill(id));
      await settleMission(tester);
      expect(c.read(overviewFocusProvider).peeked, id);
      await mouse.moveTo(Offset.zero);
      await unmountMission(tester);
    });

    testWidgets('under a thumb the box shows only while picking', (
      tester,
    ) async {
      final c = await pump(tester, size: const Size(390, 1400));
      const id = 'ks-r32-sub2';
      await reveal(tester, pill(id));
      final box = find.byKey(const ValueKey('overview-tree-select:$id'));
      expect(box, findsNothing);
      await tester.longPress(pill(id));
      await settleMission(tester);
      expect(c.read(overviewSelectionProvider).contains(id), isTrue);
      expect(box, findsOneWidget);
      expect(tester.widget<Checkbox>(box).value, isTrue);
      await unmountMission(tester);
    });

    testWidgets('under a thumb the pick box is a thumb\'s target, its face '
        'on the avatar, and the pill and the knob still take theirs', (
      tester,
    ) async {
      final c = await pump(tester, size: const Size(390, 1400));
      bool picked(String id) => c.read(overviewSelectionProvider).contains(id);
      await showAll(tester);
      const leaf = 'ks-r32-sub2';
      await reveal(tester, pill(leaf));
      await tester.longPress(pill(leaf));
      await settleMission(tester);
      expect(picked(leaf), isTrue);

      final avatar = tester.getRect(
        find.byKey(const ValueKey('session-avatar:$leaf')),
      );
      final face = tester.getRect(
        find.byKey(const ValueKey('overview-tree-select:$leaf')),
      );
      expect(avatar.contains(face.center), isTrue);
      expect(face.width, lessThan(Touch.target));
      final hit = find.byKey(const ValueKey('overview-tree-select-hit:$leaf'));
      final target = tester.getRect(hit);
      expect(target.width, greaterThanOrEqualTo(Touch.target));
      expect(target.height, greaterThanOrEqualTo(Touch.target));
      // Its far corner, outside the face, is the box's.
      await tester.tapAt(target.bottomRight - const Offset(2, 2));
      await settleMission(tester);
      expect(picked(leaf), isFalse);

      // The pill's own long press still picks, and its tap still unpicks.
      await tester.longPress(pill(leaf));
      await settleMission(tester);
      expect(picked(leaf), isTrue);
      await tester.tap(pill(leaf));
      await settleMission(tester);
      expect(picked(leaf), isFalse);

      // And the knob still folds, its box showing over a parent's avatar.
      const parent = 'ks-r32-sub0';
      c.read(overviewSelectionProvider.notifier).toggle(parent);
      await reveal(tester, knob(parent));
      await tester.tap(knob(parent));
      await settleMission(tester);
      expect(c.read(overviewFoldedParentsProvider), {parent});
      expect(picked(parent), isTrue);
      await unmountMission(tester);
    });

    testWidgets('typing in the strip\'s search leaves J, K and Enter to it', (
      tester,
    ) async {
      final c = await pump(tester);
      String? selected() => c.read(overviewFocusProvider).selected;
      // The board's keys work while nothing types.
      await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
      await settleMission(tester);
      final first = selected();
      expect(first, isNotNull);

      await tester.tap(find.byKey(const ValueKey('overview-search')));
      await settleMission(tester);
      final now = selected();
      for (final key in [
        LogicalKeyboardKey.keyJ,
        LogicalKeyboardKey.keyK,
        LogicalKeyboardKey.enter,
      ]) {
        await tester.sendKeyEvent(key);
        await settleMission(tester);
      }
      expect(selected(), now);
      expect(c.read(overviewFocusProvider).peeked, isNull);
      expect(sent(c), isEmpty, reason: 'nothing typed, nothing sent');
      await unmountMission(tester);
    });

    testWidgets('under a thumb nothing glows: hover is a pointer\'s', (
      tester,
    ) async {
      await pump(tester, size: const Size(390, 1400));
      await reveal(tester, pill('ks-r32-sub3'));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(pill('ks-r32-sub3')));
      await settleMission(tester);
      expect(
        tester
            .widget<SessionAvatar>(
              find.byWidgetPredicate(
                (w) => w is SessionAvatar && w.card.id == 'ks-r32-sub3',
              ),
            )
            .glow,
        isFalse,
      );
      expect(
        tester.getSize(pill('ks-r32-sub3')).height,
        greaterThanOrEqualTo(Touch.target),
      );
      await mouse.moveTo(Offset.zero);
      await unmountMission(tester);
    });

    testWidgets('a child in another lane is a root there that goes to its '
        'parent', (tester) async {
      final c = await pump(tester);
      final link = find.byKey(
        const ValueKey('overview-link-elsewhere:beej-for-r32'),
      );
      await reveal(tester, link);
      expect(
        find.descendant(of: familyCard('beej-for-r32'), matching: link),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('overview-jump-parent:beej-for-r32')),
      );
      await settleMission(tester);
      expect(c.read(overviewFocusProvider).selected, 'ks-r32');
      // Waiting on you, it says whose it is from the drawer too.
      await openWaiting(tester);
      expect(
        find.byKey(const ValueKey('overview-link-elsewhere:ks-r32-ask')),
        findsOneWidget,
      );
      await unmountMission(tester);
    });

    testWidgets('a detached session is a root of its own with no link', (
      tester,
    ) async {
      await pump(tester);
      final family = familyCard('ks-detached');
      await reveal(tester, family);
      for (final key in [
        'overview-link-elsewhere:ks-detached',
        'overview-parent-chip:ks-detached',
      ]) {
        expect(find.byKey(ValueKey(key)), findsNothing, reason: key);
      }
      await unmountMission(tester);
    });

    testWidgets('a pipeline stage stays in its run, on no tree', (
      tester,
    ) async {
      final c = await pump(tester, pipeline: true);
      final ids = [
        for (final lane in c.read(overviewBoardProvider).lanes)
          for (final column in BoardColumn.values)
            for (final card in lane.cards(column)) card.id,
      ];
      expect(ids, isNot(contains('ks-r32-sub1')));
      expect(ids, contains('ks-r32-sub0'));
      await showAll(tester);
      await reveal(tester, pill('ks-r32-sub0'));
      expect(pill('ks-r32-sub1'), findsNothing);
      await unmountMission(tester);
    });

    testWidgets('360 px at 1.6x: a family five deep fits, its deepest '
        'opened in the peek', (tester) async {
      final chain = [
        _card('n0', AgentState.working),
        for (var i = 1; i <= 5; i++)
          _card('n$i', AgentState.working, parent: 'n${i - 1}'),
      ];
      final c = await pumpMission(
        tester,
        fixture: _fixture(),
        prefsDir: dir,
        size: const Size(360, 900),
        phone: true,
        textScale: 1.6,
        overrides: [
          overviewQuickMessageProvider.overrideWith(_SpyMessage.new),
          overviewBoardProvider.overrideWith((ref) => _board({'ks': chain})),
        ],
      );
      await reveal(tester, pill('n5'));
      expect(tester.takeException(), isNull);
      // Past the deepest step in, a sub-session lines up under its parent.
      final x = tester.getTopLeft(pill('n3')).dx;
      expect(tester.getTopLeft(pill('n4')).dx, x);
      expect(tester.getTopLeft(pill('n5')).dx, x);
      await tester.tap(pill('n5'));
      await settleMission(tester);
      expect(c.read(overviewFocusProvider).peeked, 'n5');
      expect(tester.takeException(), isNull);
      await unmountMission(tester);
    });

    for (final width in const [360.0, 1440.0]) {
      for (final scale in const [1.0, 1.6]) {
        testWidgets('${width.toInt()} px at ${scale}x: a pointer over a pill '
            'leaves its size and its title where they were', (tester) async {
          await pump(
            tester,
            size: Size(width, 900),
            textScale: scale,
            phone: false,
          );
          const id = 'ks-r32-sub3';
          await reveal(tester, pill(id));
          final title = find.descendant(
            of: pill(id),
            matching: find.byKey(const ValueKey('overview-card-title:$id')),
          );
          // The pill slides as a whole on hover; the title within it stays.
          (Size, Offset) measure() => (
            tester.getSize(pill(id)),
            tester.getTopLeft(title) - tester.getTopLeft(pill(id)),
          );
          final rest = measure();
          final mouse = await tester.createGesture(
            kind: PointerDeviceKind.mouse,
          );
          addTearDown(mouse.removePointer);
          await mouse.addPointer(location: Offset.zero);
          await mouse.moveTo(tester.getCenter(pill(id)));
          await settleMission(tester);
          expect(measure(), rest, reason: 'hovered');
          // No box in the title row: it takes the avatar's face.
          expect(
            find.descendant(of: pill(id), matching: find.byType(Checkbox)),
            findsNothing,
          );
          await mouse.moveTo(Offset.zero);
          await settleMission(tester);
          expect(measure(), rest, reason: 'after hover');
          expect(tester.takeException(), isNull);
          await unmountMission(tester);
        });

        testWidgets('${width.toInt()} px at ${scale}x: folded at a branch '
            'and at the root, the family fits', (tester) async {
          final c = await pump(
            tester,
            size: Size(width, 900),
            textScale: scale,
          );
          await showAll(tester);
          await reveal(tester, knob('ks-r32-sub0'));
          await tester.tap(knob('ks-r32-sub0'));
          await settleMission(tester);
          expect(
            find.byKey(const ValueKey('overview-tree-folded-line:ks-r32-sub0')),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
          c.read(overviewFoldedParentsProvider.notifier).toggle('ks-r32');
          await settleMission(tester);
          final strip = find.byKey(
            const ValueKey('overview-tree-strip:ks-r32'),
          );
          await reveal(tester, strip);
          expect(strip, findsOneWidget);
          expect(tester.takeException(), isNull);
          await unmountMission(tester);
        });

        testWidgets('${width.toInt()} px at ${scale}x: the family fits, '
            'nested, and a nested pill opens the peek', (tester) async {
          final c = await pump(
            tester,
            size: Size(width, 900),
            textScale: scale,
          );
          await showAll(tester);
          await reveal(tester, pill('ks-r32-sub0-a'));
          expect(tester.takeException(), isNull);
          await tester.tap(pill('ks-r32-sub0-a'));
          await settleMission(tester);
          expect(c.read(overviewFocusProvider).peeked, 'ks-r32-sub0-a');
          expect(tester.takeException(), isNull);
          await unmountMission(tester);
        });
      }
    }

    for (final (width, scale) in const [(360.0, 1.6), (1440.0, 1.0)]) {
      testWidgets('${width.toInt()} px at ${scale}x: a parent that ended '
          'heads its ready family, its chip saying Ended', (tester) async {
        await pump(
          tester,
          size: Size(width, 900),
          textScale: scale,
          fixture: MissionFixture(
            sessions: [
              _s('ks-wrap', 'Wrapped up', AgentState.ended),
              _s(
                'ks-wrap-c',
                'Its helper',
                AgentState.ready,
                parent: 'ks-wrap',
              ),
              _s('ks-lone', 'Lone stopped', AgentState.ended),
            ],
          ),
        );
        final card = familyCard('ks-wrap');
        await reveal(tester, card);
        expect(
          find.descendant(of: card, matching: pill('ks-wrap-c')),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('overview-family-state:ks-wrap')),
            matching: find.textContaining(RegExp(r'^Ended')),
          ),
          findsOneWidget,
        );
        // Its Archive takes the whole family.
        expect(
          find.byKey(const ValueKey('overview-archive-family:ks-wrap')),
          findsOneWidget,
        );
        // Drawn once, as a sub-session; the lone one is a family of its own.
        expect(familyCard('ks-wrap-c'), findsNothing);
        final lone = familyCard('ks-lone');
        await reveal(tester, lone);
        expect(
          find.byKey(const ValueKey('overview-done-archive:ks-lone')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await unmountMission(tester);
      });
    }
  });
}
