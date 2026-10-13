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
    show overviewSectionsOf;
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
  Duration age = const Duration(minutes: 4),
}) => (
  id: id,
  title: title,
  project: project,
  machine: 'windows',
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

/// Keeps what the tree's composers send, and sends it at once — or, while
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
}) => OverviewCard(
  entry: WorkspaceSessionEntry(
    id: id,
    title: 'T $id',
    createdAt: MissionFixture.now,
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

/// **The dashboard's session tree** (round 92): a family is one tree — the
/// root's avatar with its card attached, its sub-sessions branching off a
/// stem, theirs nested one level further — opening inline, folding to its
/// root, lit together under a pointer, and a child drawn apart from its
/// parent a jump away.
void main() {
  group('the forest', () {
    test('a root, its branches and their nesting, each family once', () {
      final board = _board({
        'ks': [
          _card('p', AgentState.working),
          _card('c', AgentState.working, parent: 'p'),
          _card('g', AgentState.ready, parent: 'c'),
          _card('d', AgentState.ended, parent: 'p'),
          _card('ask', AgentState.needsYou, parent: 'p'),
          _card('other', AgentState.working),
          _card('stray', AgentState.working, parent: 'gone'),
        ],
      });
      final forest = overviewForestOf(board);
      final work = forest.work.single.$2;
      expect(
        work.map(_shape),
        unorderedEquals(['p(ask c(g) d)', 'other', 'stray']),
      );
      expect(forest.ready, isEmpty);
      expect(forest.placed, {'p', 'c', 'g', 'd', 'ask', 'other', 'stray'});
      final p = work.firstWhere((t) => t.card.id == 'p');
      // Most urgent first: what waits on you, then what works, then done.
      expect([for (final c in p.children) c.card.id], ['ask', 'c', 'd']);
      expect([for (final c in p.descendants) c.id], ['ask', 'c', 'g', 'd']);
    });

    test('a session on its own is a root with no branches; a ready family '
        'is in the ready lane, newest first', () {
      final board = _board({
        'ks': [
          _card('solo', AgentState.ready),
          _card('r', AgentState.ready),
          _card('rc', AgentState.ended, parent: 'r'),
        ],
      });
      final forest = overviewForestOf(board);
      expect(forest.work, isEmpty);
      expect(forest.ready.map(_shape), unorderedEquals(['solo', 'r(rc)']));
    });

    test('a parent held by a sub-session that waits on you roots its family '
        'at work; the sub-session alone waits in the queue', () {
      final held = _card('p', AgentState.needsYou, waitingOn: 1);
      expect(held.heldBySubSessions, isTrue);
      final board = _board({
        'ks': [held, _card('c', AgentState.needsYou, parent: 'p')],
      });
      expect(overviewForestOf(board).work.single.$2.map(_shape), ['p(c)']);
    });

    test('a child in another lane is a root there, never split into its '
        'parent\'s', () {
      final board = _board({
        'ks': [_card('p', AgentState.working)],
        'beej': [_card('c', AgentState.working, parent: 'p')],
      });
      final forest = overviewForestOf(board);
      expect(
        {for (final (lane, trees) in forest.work) lane.key: trees.map(_shape)},
        {
          'ks': ['p'],
          'beej': ['c'],
        },
      );
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
      ).work.single.$2.single;
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
      ).work.single.$2.single;
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
    }) => pumpMission(
      tester,
      fixture: _fixture(),
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
    Finder detail(String id) =>
        find.byKey(ValueKey('overview-tree-detail:$id'));

    testWidgets('a family is one tree: the root card with its avatar, its '
        'sub-sessions on branches, and theirs nested a level further', (
      tester,
    ) async {
      await pump(tester);
      final family = find.byKey(const ValueKey('overview-family:ks-r32'));
      await reveal(tester, family);
      Finder inFamily(Finder f) => find.descendant(of: family, matching: f);
      expect(
        inFamily(find.byKey(const ValueKey('overview-work-card:ks-r32'))),
        findsOneWidget,
      );
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
      // The root's avatar sits over its card's edge; a branch's avatar is
      // smaller and to the right of the stem.
      final root = tester.getRect(
        find.byKey(const ValueKey('session-avatar:ks-r32')),
      );
      final card = tester.getRect(
        find.byKey(const ValueKey('overview-card:ks-r32')),
      );
      expect(root.size, const Size.square(Chrome.sessionAvatar));
      expect(card.left, closeTo(root.center.dx, 1));
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
      final solo = find.byKey(const ValueKey('overview-family:ks-release'));
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

    testWidgets('a pill opens inline and closes on a second click', (
      tester,
    ) async {
      final c = await pump(tester);
      await reveal(tester, pill('ks-r32-sub2'));
      expect(detail('ks-r32-sub2'), findsNothing);
      await tester.tap(pill('ks-r32-sub2'));
      await settleMission(tester);
      expect(detail('ks-r32-sub2'), findsOneWidget);
      // Its actions: Archive, Hand back to the parent, Open chat, the menu.
      for (final key in [
        'overview-done-archive:ks-r32-sub2',
        'overview-hand-back:ks-r32-sub2',
        'overview-tree-open:ks-r32-sub2',
        'overview-card-menu:ks-r32-sub2',
      ]) {
        expect(
          find.descendant(
            of: detail('ks-r32-sub2'),
            matching: find.byKey(ValueKey(key)),
          ),
          findsOneWidget,
          reason: key,
        );
      }
      // Opening is not peeking.
      expect(c.read(overviewFocusProvider).peeked, isNull);
      await tester.tap(pill('ks-r32-sub2'));
      await settleMission(tester);
      expect(detail('ks-r32-sub2'), findsNothing);
      await unmountMission(tester);
    });

    testWidgets('a pill takes the keys: Enter and Space toggle it', (
      tester,
    ) async {
      await pump(tester);
      await reveal(tester, pill('ks-r32-sub3'));
      // The pill's own focus: the nearest one above what it draws.
      Focus.of(
        tester.element(
          find
              .descendant(
                of: pill('ks-r32-sub3'),
                matching: find.byType(OverviewHoverScope),
              )
              .first,
        ),
      ).requestFocus();
      await settleMission(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settleMission(tester);
      expect(detail('ks-r32-sub3'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settleMission(tester);
      expect(detail('ks-r32-sub3'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await settleMission(tester);
      expect(detail('ks-r32-sub3'), findsOneWidget);
      await unmountMission(tester);
    });

    testWidgets('folding keeps only the root, saying how many are away', (
      tester,
    ) async {
      final c = await pump(tester);
      final line = find.byKey(const ValueKey('overview-children-line:ks-r32'));
      await reveal(tester, line);
      expect(tester.widget<Text>(line).data, '7 sub-sessions');
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('overview-family-summary:ks-r32')),
            )
            .data,
        '3 of 7 done · 1 needs you · 3 working',
      );
      await tester.tap(
        find.byKey(const ValueKey('overview-children-fold:ks-r32')),
      );
      await settleMission(tester);
      expect(c.read(overviewFoldedParentsProvider), {'ks-r32'});
      expect(pill('ks-r32-sub0'), findsNothing);
      expect(pill('ks-r32-sub0-a'), findsNothing);
      expect(line, findsOneWidget);
      // What waits on you stays answerable in the queue.
      expect(
        find.byKey(const ValueKey('overview-queue-card:ks-r32-ask')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('overview-children-fold:ks-r32')),
      );
      await settleMission(tester);
      expect(pill('ks-r32-sub0'), findsOneWidget);
      await unmountMission(tester);
    });

    Finder knob(String id) => find.byKey(ValueKey('overview-tree-knob:$id'));

    testWidgets('a knob on the stem folds the family to one strip that '
        'still counts what needs you, and Show unfolds it', (tester) async {
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
      expect(pill('ks-r32-sub0'), findsNothing);
      final strip = find.byKey(const ValueKey('overview-tree-strip:ks-r32'));
      expect(strip, findsOneWidget);
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('overview-tree-folded-summary:ks-r32')),
            )
            .data,
        '7 sub-sessions · 3 of 7 done · 1 needs you · 3 working',
      );
      expect(
        find.descendant(of: strip, matching: find.text('Show')),
        findsOneWidget,
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
      expect(pill('ks-r32-sub0'), findsOneWidget);
      semantics.dispose();
      await unmountMission(tester);
    });

    testWidgets('an inner node folds: its children go, and its pill says '
        'what it hides', (tester) async {
      final c = await pump(tester);
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
          waitingSince: (_) => null,
          folded: c.read(overviewFoldedParentsProvider),
        ).work)
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
      await reveal(tester, knob('ks-r32-sub0'));
      final size = tester.getSize(knob('ks-r32-sub0'));
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
      final parent = find.byKey(const ValueKey('overview-work-card:ks-r32'));
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
        'picks; Open chat over the state opens the chat', (tester) async {
      final c = await pump(tester);
      const id = 'ks-r32-sub2';
      await reveal(tester, pill(id));
      final box = find.byKey(const ValueKey('overview-tree-select:$id'));
      final chat = find.byKey(const ValueKey('overview-tree-chat:$id'));
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
      expect(detail(id), findsNothing, reason: 'picking is not opening');
      await tester.tap(box);
      await settleMission(tester);
      expect(c.read(overviewSelectionProvider).isEmpty, isTrue);

      await mouse.moveTo(tester.getCenter(pill(id)));
      await settleMission(tester);
      await tester.tap(chat);
      await settleMission(tester);
      expect(c.read(overviewFocusProvider).peeked, id);
      await mouse.moveTo(Offset.zero);
      await unmountMission(tester);
    });

    testWidgets('under a thumb the box shows only while picking, and no '
        'hover actions', (tester) async {
      final c = await pump(tester, size: const Size(390, 1400));
      const id = 'ks-r32-sub2';
      await reveal(tester, pill(id));
      final box = find.byKey(const ValueKey('overview-tree-select:$id'));
      expect(box, findsNothing);
      expect(
        find.byKey(const ValueKey('overview-tree-chat:$id')),
        findsNothing,
      );
      await tester.longPress(pill(id));
      await settleMission(tester);
      expect(c.read(overviewSelectionProvider).contains(id), isTrue);
      expect(box, findsOneWidget);
      expect(tester.widget<Checkbox>(box).value, isTrue);
      await unmountMission(tester);
    });

    Finder composerIn(Finder scope, String id) => find.descendant(
      of: scope,
      matching: find.byKey(ValueKey('overview-composer:$id')),
    );

    testWidgets('an opened sub-session takes a message in its detail; Enter '
        'sends it and leaves the detail open', (tester) async {
      final c = await pump(tester);
      const id = 'ks-r32-sub2';
      await reveal(tester, pill(id));
      await tester.tap(pill(id));
      await settleMission(tester);
      final field = composerIn(detail(id), id);
      expect(field, findsOneWidget);
      // Above its actions.
      expect(
        tester.getRect(field).bottom,
        lessThan(
          tester
              .getRect(find.byKey(const ValueKey('overview-tree-open:$id')))
              .top,
        ),
      );
      await tester.tap(field);
      await tester.enterText(field, 'Commit it');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settleMission(tester);
      expect(sent(c), [(id, 'Commit it')]);
      expect(detail(id), findsOneWidget, reason: 'Enter is the composer\'s');
      await unmountMission(tester);
    });

    testWidgets('the hover\'s Message opens one composer under the pill; a '
        'send closes it and the pill says it went', (tester) async {
      final c = await pump(tester);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      Finder composer(String id) =>
          find.byKey(ValueKey('overview-tree-composer:$id'));
      Future<void> message(String id) async {
        await reveal(tester, pill(id));
        await mouse.moveTo(tester.getCenter(pill(id)));
        await settleMission(tester);
        await tester.tap(find.byKey(ValueKey('overview-tree-message:$id')));
        await settleMission(tester);
      }

      await message('ks-r32-sub2');
      expect(composer('ks-r32-sub2'), findsOneWidget);
      expect(detail('ks-r32-sub2'), findsNothing);
      // One composer in a family at a time.
      await message('ks-r32-sub3');
      expect(composer('ks-r32-sub3'), findsOneWidget);
      expect(composer('ks-r32-sub2'), findsNothing);
      await mouse.moveTo(Offset.zero);
      await settleMission(tester);

      // It takes the keys as it opens.
      final field = composerIn(composer('ks-r32-sub3'), 'ks-r32-sub3');
      expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue);
      await tester.enterText(field, 'Open a draft PR');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settleMission(tester);
      expect(sent(c), [('ks-r32-sub3', 'Open a draft PR')]);
      expect(composer('ks-r32-sub3'), findsNothing);
      final went = find.byKey(const ValueKey('overview-tree-sent:ks-r32-sub3'));
      expect(
        find.descendant(of: went, matching: find.text('Sent')),
        findsOneWidget,
      );
      await unmountMission(tester);
    });

    testWidgets('folding an inner node keeps its own composer: the draft, '
        'and a send in flight', (tester) async {
      final c = await pump(tester);
      const id = 'ks-r32-sub0';
      await reveal(tester, pill(id));
      await tester.tap(pill(id));
      await settleMission(tester);
      final field = composerIn(detail(id), id);
      String draft() => tester.widget<TextField>(field).controller!.text;
      await tester.enterText(field, 'half a reply');
      final fold = c.read(overviewFoldedParentsProvider.notifier);
      fold.toggle(id);
      await settleMission(tester);
      expect(pill('ks-r32-sub0-a'), findsNothing);
      expect(draft(), 'half a reply', reason: 'folded');
      fold.toggle(id);
      await settleMission(tester);
      expect(pill('ks-r32-sub0-a'), findsOneWidget);
      expect(draft(), 'half a reply', reason: 'unfolded');

      final hold = (c.read(overviewQuickMessageProvider) as _SpyMessage).hold =
          Completer<void>();
      await tester.showKeyboard(field);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      fold.toggle(id);
      await settleMission(tester);
      hold.complete();
      await settleMission(tester);
      expect(sent(c), [(id, 'half a reply')]);
      expect(draft(), isEmpty);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('overview-composer-said:$id')),
          matching: find.text('Sent'),
        ),
        findsOneWidget,
      );
      await unmountMission(tester);
    });

    testWidgets('Esc closes the pill\'s composer and sends nothing', (
      tester,
    ) async {
      final c = await pump(tester);
      const id = 'ks-r32-sub2';
      await reveal(tester, pill(id));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(pill(id)));
      await settleMission(tester);
      await tester.tap(find.byKey(const ValueKey('overview-tree-message:$id')));
      await settleMission(tester);
      final composer = find.byKey(const ValueKey('overview-tree-composer:$id'));
      await tester.enterText(composerIn(composer, id), 'half a thought');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settleMission(tester);
      expect(composer, findsNothing);
      expect(sent(c), isEmpty);
      await mouse.moveTo(Offset.zero);
      await unmountMission(tester);
    });

    testWidgets('the parent card has its own composer, a family or alone', (
      tester,
    ) async {
      final c = await pump(tester);
      for (final id in ['ks-r32', 'ks-release']) {
        final family = find.byKey(ValueKey('overview-family:$id'));
        await reveal(tester, family);
        expect(
          composerIn(find.byKey(ValueKey('overview-card:$id')), id),
          findsOneWidget,
          reason: id,
        );
      }
      final field = composerIn(
        find.byKey(const ValueKey('overview-card:ks-release')),
        'ks-release',
      );
      await tester.tap(field);
      await tester.enterText(field, 'Ship it');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settleMission(tester);
      expect(sent(c), [('ks-release', 'Ship it')]);
      expect(c.read(overviewFocusProvider).peeked, isNull);
      await unmountMission(tester);
    });

    testWidgets('typing in a composer leaves J, K and Enter to it', (
      tester,
    ) async {
      final c = await pump(tester);
      String? selected() => c.read(overviewFocusProvider).selected;
      // The board's keys work while nothing types.
      await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
      await settleMission(tester);
      final first = selected();
      expect(first, isNotNull);

      const id = 'ks-r32-sub2';
      await reveal(tester, pill(id));
      await tester.tap(pill(id));
      await settleMission(tester);
      final field = composerIn(detail(id), id);
      await tester.tap(field);
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
      expect(detail(id), findsOneWidget);
      expect(sent(c), isEmpty, reason: 'nothing typed, nothing sent');
      await unmountMission(tester);
    });

    testWidgets('under a thumb nothing glows: hover is a pointer\'s', (
      tester,
    ) async {
      await pump(tester, size: const Size(390, 1400));
      await reveal(tester, pill('ks-r32-sub0'));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(pill('ks-r32-sub0')));
      await settleMission(tester);
      expect(
        tester
            .widget<SessionAvatar>(
              find.byWidgetPredicate(
                (w) => w is SessionAvatar && w.card.id == 'ks-r32-sub0',
              ),
            )
            .glow,
        isFalse,
      );
      expect(
        tester.getSize(pill('ks-r32-sub0')).height,
        greaterThanOrEqualTo(Touch.target),
      );
      await mouse.moveTo(Offset.zero);
      await unmountMission(tester);
    });

    testWidgets('a child in another lane is a root there that names its '
        'parent and goes to it', (tester) async {
      final c = await pump(tester);
      final link = find.byKey(
        const ValueKey('overview-link-elsewhere:beej-for-r32'),
      );
      await reveal(tester, link);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('overview-family:beej-for-r32')),
          matching: link,
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('overview-family:beej-for-r32')),
          matching: find.text('↳ from Round 32 · Overview redesign'),
        ),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('overview-jump-parent:beej-for-r32')),
      );
      await settleMission(tester);
      expect(c.read(overviewFocusProvider).selected, 'ks-r32');
      // Waiting on you, it says whose it is from the queue too.
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
      final family = find.byKey(const ValueKey('overview-family:ks-detached'));
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
      await reveal(tester, pill('ks-r32-sub0'));
      expect(pill('ks-r32-sub1'), findsNothing);
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
          const id = 'ks-r32-sub0';
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
            'and at the root, the tree fits', (tester) async {
          final c = await pump(
            tester,
            size: Size(width, 900),
            textScale: scale,
          );
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

        testWidgets('${width.toInt()} px at ${scale}x: the tree fits, opened '
            'and nested', (tester) async {
          await pump(tester, size: Size(width, 900), textScale: scale);
          await reveal(tester, pill('ks-r32-sub0-a'));
          await tester.tap(pill('ks-r32-sub0-a'));
          await settleMission(tester);
          expect(detail('ks-r32-sub0-a'), findsOneWidget);
          expect(
            composerIn(detail('ks-r32-sub0-a'), 'ks-r32-sub0-a'),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
          await unmountMission(tester);
        });
      }
    }
  });
}
