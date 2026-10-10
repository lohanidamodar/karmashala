import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/explorer/application/agent_states.dart';
import 'package:karmashala/src/features/explorer/application/workspace_session_entry.dart';
import 'package:karmashala/src/features/overview/application/overview_board.dart';
import 'package:karmashala/src/features/overview/application/overview_links.dart';
import 'package:karmashala/src/features/overview/application/overview_prefs.dart';
import 'package:karmashala/src/features/overview/application/overview_providers.dart';
import 'package:karmashala/src/features/overview/presentation/overview_hybrid.dart';
import 'package:karmashala/src/features/pipelines/application/pipelines_controller.dart';
import 'package:karmashala_automations/pipelines.dart';

import 'mission_fixture.dart';

MissionSession _s(
  String id,
  String title,
  AgentState state, {
  String? parent,
  Duration age = const Duration(minutes: 4),
}) => (
  id: id,
  title: title,
  project: 'p-ks',
  machine: 'windows',
  agent: AgentIds.claudeCode,
  state: state,
  age: age,
  parent: parent,
  report: null,
);

/// The realistic board, plus a sub-session of a sub-session (depth 2), a
/// sub-session that needs you while its parent works (another lane), and a
/// session detached from its parent (no parent left).
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

OverviewCard _card(String id, {String? parent, String? breadcrumb}) =>
    OverviewCard(
      entry: WorkspaceSessionEntry(
        id: id,
        title: 'T $id',
        createdAt: MissionFixture.now,
      ),
      state: AgentState.working,
      parentId: parent,
      breadcrumb: breadcrumb,
    );

/// **Sub-sessions as cards, linked**: each child right after its parent and
/// tied to it — indented with a connector on a desktop, "↳ child of" on a
/// phone — the parent counting them with a fold, the family lit together,
/// a parent in another lane a jump away, and pipeline stages kept in their
/// run.
void main() {
  group('the links', () {
    final board = OverviewBoard.empty;

    test('families keep a child with its parent, and depth counts', () {
      final cards = [
        _card('p'),
        _card('c', parent: 'p'),
        _card('g', parent: 'c'),
        _card('other'),
        _card('stray', parent: 'gone'),
      ];
      expect(
        [for (final f in overviewFamiliesOf(cards)) f.map((c) => c.id).join()],
        ['pcg', 'other', 'stray'],
      );
      final links = overviewLinksOf(cards, board: board);
      expect(links['c']?.kind, OverviewLinkKind.tied);
      expect(links['c']?.depth, 1);
      expect(links['g']?.depth, 2);
      expect(links.containsKey('p'), isFalse);
      // A parent on no board at all is no link, not a broken one.
      expect(links.containsKey('stray'), isFalse);
    });

    test('a fold hides the family below the folded parent', () {
      final cards = [
        _card('p'),
        _card('c', parent: 'p'),
        _card('g', parent: 'c'),
        _card('d', parent: 'p'),
      ];
      expect(overviewUnfolded(cards, {'c'}).map((c) => c.id), ['p', 'c', 'd']);
      expect(overviewUnfolded(cards, {'p'}).map((c) => c.id), ['p']);
    });

    test('a family lights up together, and only the family', () {
      final parent = _card('p');
      final child = _card('c', parent: 'p');
      final other = _card('o');
      final onChild = OverviewLinkFocus(child.id, child.parentId);
      final onParent = OverviewLinkFocus(parent.id, null);
      expect(overviewLinkLit(parent, onChild), isTrue);
      expect(overviewLinkLit(child, onParent), isTrue);
      expect(overviewLinkLit(other, onParent), isFalse);
      expect(overviewLinkLit(child, onChild), isFalse);
    });
  });

  group('on the board', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('ks-links');
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
    }) async {
      final c = await pumpMission(
        tester,
        fixture: _fixture(),
        prefsDir: dir,
        size: size,
        phone: size.width < 600,
        textScale: textScale,
        overrides: [if (pipeline) pipelinesProvider.overrideWith(_Runs.new)],
      );
      c
          .read(overviewPrefsProvider.notifier)
          .setSubSessions(OverviewSubSessionMode.cards);
      await settleMission(tester);
      return c;
    }

    Future<void> reveal(
      WidgetTester tester,
      Finder finder, {
      double delta = 200,
    }) async {
      await tester.scrollUntilVisible(finder, delta, scrollable: hybridList);

      await settleMission(tester);
    }

    testWidgets('a child sits right after its parent, in its family, '
        'indented by depth with a connector', (tester) async {
      final c = await pump(tester);
      final work = [
        for (final card in overviewSectionsOf(
          c.read(overviewBoardProvider),
          waitingSince: (_) => null,
        ).work)
          card.id,
      ];
      final at = work.indexOf('ks-r32');
      expect(work.sublist(at + 1, at + 4), [
        'ks-r32-sub0',
        'ks-r32-sub0-a',
        'ks-r32-sub1',
      ]);
      final family = find.byKey(const ValueKey('overview-family:ks-r32'));
      await reveal(tester, family);
      for (final id in ['ks-r32-sub0', 'ks-r32-sub0-a', 'ks-r32-sub1']) {
        expect(
          find.descendant(
            of: family,
            matching: find.byKey(ValueKey('overview-work-card:$id')),
          ),
          findsOneWidget,
          reason: id,
        );
      }
      expect(
        find.byKey(const ValueKey('overview-child-indent:ks-r32-sub0:1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('overview-child-indent:ks-r32-sub0-a:2')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('overview-child-link:ks-r32')),
        findsNothing,
      );
      await unmountMission(tester);
    });

    testWidgets('the parent counts its sub-sessions, and folds them away', (
      tester,
    ) async {
      final c = await pump(tester);
      final line = find.byKey(const ValueKey('overview-children-line:ks-r32'));
      await reveal(tester, line);
      final text = tester.widget<Text>(line).data!;
      expect(text, startsWith('6 sub-sessions'));
      expect(text, contains('1 needs you'));
      expect(text, contains('2 working'));
      await tester.tap(
        find.byKey(const ValueKey('overview-children-fold:ks-r32')),
      );
      await settleMission(tester);
      expect(c.read(overviewFoldedParentsProvider), {'ks-r32'});
      expect(
        find.byKey(const ValueKey('overview-work-card:ks-r32-sub0')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('overview-work-card:ks-r32-sub0-a')),
        findsNothing,
      );
      await tester.tap(
        find.byKey(const ValueKey('overview-children-fold:ks-r32')),
      );
      await settleMission(tester);
      expect(
        find.byKey(const ValueKey('overview-work-card:ks-r32-sub0')),
        findsOneWidget,
      );
      await unmountMission(tester);
    });

    testWidgets('hovering a parent lights its children, and a child its '
        'parent', (tester) async {
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
      expect(
        find.byKey(const ValueKey('overview-link-lit:ks-r32')),
        findsNothing,
      );

      await mouse.moveTo(
        tester.getCenter(
          find.byKey(const ValueKey('overview-work-card:ks-r32-sub0')),
        ),
      );
      await settleMission(tester);
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
      await unmountMission(tester);
    });

    testWidgets('a child\'s parent chip peeks the parent', (tester) async {
      final c = await pump(tester);
      final chip = find.byKey(
        const ValueKey('overview-parent-chip:ks-r32-sub0'),
      );
      await reveal(tester, chip);
      await tester.tap(chip);
      await settleMission(tester);
      expect(c.read(overviewFocusProvider).peeked, 'ks-r32');
      await unmountMission(tester);
    });

    testWidgets('a child in another lane names its parent and jumps there, '
        'with no connector', (tester) async {
      final c = await pump(tester);
      final link = find.byKey(
        const ValueKey('overview-link-elsewhere:ks-r32-ask'),
      );
      await reveal(tester, link);
      expect(
        find.descendant(
          of: link,
          matching: find.text('↳ Round 32 · Overview redesign'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('overview-child-link:ks-r32-ask')),
        findsNothing,
      );
      await tester.tap(
        find.byKey(const ValueKey('overview-jump-parent:ks-r32-ask')),
      );
      await settleMission(tester);
      expect(c.read(overviewFocusProvider).selected, 'ks-r32');
      // Ready while its parent works: Done is another lane too.
      final ready = find.byKey(
        const ValueKey('overview-link-elsewhere:ks-r32-sub2'),
      );
      await reveal(tester, ready);
      expect(ready, findsOneWidget);
      await unmountMission(tester);
    });

    testWidgets('a detached session shows no link', (tester) async {
      await pump(tester);
      final card = find.byKey(const ValueKey('overview-work-card:ks-detached'));
      await reveal(tester, card);
      for (final key in [
        'overview-child-link:ks-detached',
        'overview-link-elsewhere:ks-detached',
        'overview-parent-chip:ks-detached',
      ]) {
        expect(find.byKey(ValueKey(key)), findsNothing, reason: key);
      }
      await unmountMission(tester);
    });

    testWidgets('a pipeline stage stays in its run, not a linked card', (
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
      expect(
        find.byKey(const ValueKey('overview-linked:ks-r32-sub1')),
        findsNothing,
      );
      await unmountMission(tester);
    });

    for (final width in const [360.0, 412.0]) {
      for (final scale in const [1.0, 1.6]) {
        testWidgets('a phone at ${width.toInt()} px and $scale says '
            '"child of" instead of indenting', (tester) async {
          await pump(tester, size: Size(width, 900), textScale: scale);
          final line = find.byKey(
            const ValueKey('overview-child-of:ks-r32-sub0'),
          );
          await reveal(tester, line);
          expect(
            find.descendant(
              of: line,
              matching: find.text('↳ child of Round 32 · Overview redesign'),
            ),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('overview-child-indent:ks-r32-sub0:1')),
            findsNothing,
          );
          await reveal(
            tester,
            find.byKey(const ValueKey('overview-child-of:ks-r32-sub0-a')),
          );
          await reveal(
            tester,
            find.byKey(const ValueKey('overview-link-elsewhere:ks-r32-ask')),
            // The queue is above the work on a phone.
            delta: -200,
          );
          expect(tester.takeException(), isNull);
          await unmountMission(tester);
        });
      }
    }

    for (final scale in const [1.0, 1.6]) {
      testWidgets('a desktop at $scale fits the families', (tester) async {
        await pump(tester, size: const Size(1440, 900), textScale: scale);
        await reveal(
          tester,
          find.byKey(const ValueKey('overview-child-link:ks-r32-sub0-a')),
        );
        expect(tester.takeException(), isNull);
        await unmountMission(tester);
      });
    }
  });
}
