import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/explorer/application/agent_states.dart';
import 'package:karmashala/src/features/overview/application/overview_board.dart';
import 'package:karmashala/src/features/overview/application/overview_family_order.dart';
import 'package:karmashala/src/features/overview/application/overview_prefs.dart';
import 'package:karmashala/src/features/overview/application/overview_providers.dart';
import 'package:karmashala/src/features/overview/application/overview_shown.dart';
import 'package:karmashala/src/features/overview/application/overview_tree.dart';
import 'package:karmashala/src/features/overview/presentation/overview_project_tile.dart';
import 'package:karmashala/src/features/overview/presentation/overview_strip.dart';

import 'mission_fixture.dart';

/// **The dashboard is project tiles** (owner, 2026-11-12): one tile per
/// project, saying what its sessions do; a card for a family that needs
/// you, runs or is new, one line for one finished and seen; and nothing
/// changes place when a session changes state.
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ks-overview-tiles');
  });
  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } on FileSystemException {
      // The prefs file may still be held open on Windows; the OS sweeps temp.
    }
  });

  Finder byKey(String key) => find.byKey(ValueKey(key));
  Finder tile(String key) => byKey('overview-tile:$key');
  Finder line(String id) => byKey('overview-line:$id');

  MissionSession s(
    String id,
    String title, {
    String project = 'p-ks',
    AgentState state = AgentState.ended,
    int age = 5,
    String agent = AgentIds.claudeCode,
  }) => (
    id: id,
    title: title,
    project: project,
    machine: 'windows',
    agent: agent,
    state: state,
    age: Duration(minutes: age),
    parent: null,
    report: null,
  );

  testWidgets('one tile per project; a finished, seen family is one line, '
      'the rest are cards', (tester) async {
    await pumpMission(
      tester,
      fixture: MissionFixture.full(),
      prefsDir: dir,
      lines: true,
    );
    for (final project in ['p-ks', 'p-beej', 'p-store', 'p-relay']) {
      expect(tile(project), findsOneWidget, reason: project);
    }
    // Ready and seen, and ended: a line each, in its project's tile.
    for (final id in ['ks-r30', 'ks-r29', 'beej-ci']) {
      expect(line(id), findsOneWidget, reason: id);
      expect(familyCard(id), findsNothing, reason: id);
    }
    expect(
      find.descendant(of: tile('p-ks'), matching: line('ks-r30')),
      findsOneWidget,
    );
    // What needs you or runs keeps its card.
    for (final id in ['ks-r21', 'ks-r32', 'beej-scaffold']) {
      expect(familyCard(id), findsOneWidget, reason: id);
      expect(line(id), findsNothing, reason: id);
    }
    // The header counts what matters in the project.
    final counts = tester.widget<Text>(byKey('overview-tile-counts:p-ks'));
    expect(counts.textSpan!.toPlainText(), '1 needs you · 5 running');
    await unmountMission(tester);
  });

  testWidgets('a line opens its chat, is a card while the chat is open, and '
      'a line again after', (tester) async {
    final c = await pumpMission(
      tester,
      fixture: MissionFixture.full(),
      prefsDir: dir,
      lines: true,
    );
    await tester.tap(line('ks-r30'));
    await settleMission(tester);
    expect(c.read(overviewFocusProvider).peeked, 'ks-r30');
    expect(familyCard('ks-r30'), findsOneWidget);
    expect(line('ks-r30'), findsNothing);

    c.read(overviewFocusProvider.notifier).closePeek();
    await settleMission(tester);
    expect(line('ks-r30'), findsOneWidget);
    expect(familyCard('ks-r30'), findsNothing);
    await unmountMission(tester);
  });

  testWidgets('a session that starts running becomes a card where it was: '
      'no family and no tile changes place', (tester) async {
    final c = await pumpMission(
      tester,
      fixture: MissionFixture.full(),
      prefsDir: dir,
      lines: true,
    );
    List<String> roots() => [
      for (final (_, trees) in c.read(overviewForestProvider).lanes)
        for (final tree in trees) tree.card.id,
    ];
    final before = roots();
    final tilesBefore = [
      for (final project in MissionFixture.projects)
        if (tile(project.id).evaluate().isNotEmpty)
          tester.getTopLeft(tile(project.id)).dx,
    ];
    c.read(missionStatesProvider.notifier).flip('ks-r30', AgentState.working);
    await settleMission(tester);

    expect(familyCard('ks-r30'), findsOneWidget);
    expect(line('ks-r30'), findsNothing);
    expect(roots(), before);
    expect([
      for (final project in MissionFixture.projects)
        if (tile(project.id).evaluate().isNotEmpty)
          tester.getTopLeft(tile(project.id)).dx,
    ], tilesBefore);
    await unmountMission(tester);
  });

  testWidgets('the five lines last active stay; older ones fold behind '
      '"Show N more", and the selection is never left folded', (tester) async {
    final c = await pumpMission(
      tester,
      fixture: MissionFixture(
        sessions: [
          for (var i = 1; i <= 7; i++) s('e$i', 'Ended $i', age: i * 10),
          s('run', 'Running', state: AgentState.working),
        ],
      ),
      prefsDir: dir,
      lines: true,
    );
    for (var i = 1; i <= 5; i++) {
      expect(line('e$i'), findsOneWidget);
    }
    expect(line('e6'), findsNothing);
    expect(line('e7'), findsNothing);
    expect(find.text('Show 2 more'), findsOneWidget);

    // A hidden one the keys land on is drawn.
    c.read(overviewFocusProvider.notifier).select('e7');
    await settleMission(tester);
    expect(line('e7'), findsOneWidget);
    expect(find.text('Show 1 more'), findsOneWidget);

    await tester.tap(byKey('overview-tile-more:p-ks'));
    await settleMission(tester);
    expect(line('e6'), findsOneWidget);
    expect(find.text('Show fewer'), findsOneWidget);
    await unmountMission(tester);
  });

  testWidgets('grouped by context, each group holds its projects\' tiles', (
    tester,
  ) async {
    final c = await pumpMission(
      tester,
      fixture: MissionFixture(
        contexts: const [OverviewLaneKey('c-pb', 'PopupBits')],
        contextOfProject: const {'p-ks': 'c-pb', 'p-beej': 'c-pb'},
      ),
      prefsDir: dir,
      lines: true,
    );
    c.read(overviewPrefsProvider.notifier).setGroupBy(OverviewGroupBy.context);
    await settleMission(tester);

    Finder group(String key) => find.byWidgetPredicate(
      (w) => w is OverviewLaneHeader && w.lane.key == key,
    );
    expect(group('c-pb'), findsOneWidget);
    expect(group(kOverviewUnfiledLane), findsOneWidget);
    expect(tile('p-ks'), findsOneWidget);
    expect(tile('p-beej'), findsOneWidget);
    // The context's tiles sit under its header, the rest under No context.
    final none = tester.getTopLeft(group(kOverviewUnfiledLane)).dy;
    expect(tester.getTopLeft(tile('p-ks')).dy, lessThan(none));
    expect(tester.getTopLeft(tile('p-beej')).dy, lessThan(none));
    expect(tester.getTopLeft(tile('p-store')).dy, greaterThan(none));

    // A tile folds within its group, and its sessions leave the keys' walk.
    await tester.tap(byKey('overview-lane-fold:p-beej'));
    await settleMission(tester);
    expect(familyCard('beej-scaffold'), findsNothing);
    expect(tile('p-beej'), findsOneWidget);
    expect(
      c.read(overviewOpenForestProvider).placed,
      isNot(contains('beej-scaffold')),
    );
    expect(familyCard('ks-r32'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await unmountMission(tester);
  });

  for (final (size, scale) in [
    (const Size(360, 800), 1.6),
    (const Size(360, 800), 1.0),
    (const Size(1024, 768), 1.0),
    (const Size(1440, 900), 1.6),
  ]) {
    testWidgets(
      '${size.width.toInt()} px at ${scale}x: tiles and lines fit, folded '
      'and open',
      (tester) async {
        await pumpMission(
          tester,
          fixture: MissionFixture.full(),
          prefsDir: dir,
          size: size,
          phone: size.width < 600,
          textScale: scale,
          lines: true,
        );
        expect(tester.takeException(), isNull);
        expect(tile('p-ks'), findsOneWidget);
        final box = tester.getRect(tile('p-ks'));
        expect(box.left, greaterThanOrEqualTo(0));
        expect(box.right, lessThanOrEqualTo(size.width));
        await tester.tap(byKey('overview-lane-fold:p-ks'));
        await settleMission(tester);
        expect(familyCard('ks-r21'), findsNothing);
        expect(byKey('overview-lane-folded-asks:p-ks'), findsOneWidget);
        await tester.drag(hybridList, const Offset(0, -6000));
        await settleMission(tester);
        expect(tester.takeException(), isNull);
        await unmountMission(tester);
      },
    );
  }

  group('the tiles of a group', () {
    test('are in the projects\' own order, one for no project last', () {
      final fixture = MissionFixture(
        sessions: [
          s('a', 'A', project: 'p-relay', state: AgentState.working),
          s('b', 'B', project: 'p-ks', state: AgentState.working),
          s('c', 'C', project: 'p-ks', state: AgentState.ready),
        ],
      );
      final board = buildOverviewBoard(
        fixture.groups,
        facts: fixture.facts,
        filter: const OverviewFilter(),
        groupBy: OverviewGroupBy.machine,
        startOfToday: MissionFixture.now.subtract(const Duration(days: 1)),
        memo: BoardOrderMemo(),
      );
      final forest = overviewForestOf(board);
      final tiles = overviewTilesOf(forest.lanes.single.$2, fixture.facts);
      expect([for (final tile in tiles) tile.key], ['p-ks', 'p-relay']);
      expect([for (final tree in tiles.first.trees) tree.card.id], ['b', 'c']);
      expect(tiles.first.label, 'karmashala');
    });

    test('a tile folded under Project is its group\'s own fold; under '
        'another grouping it is named within its group', () {
      expect(
        overviewTileFoldId(OverviewGroupBy.project, 'p-ks', 'p-ks'),
        'p-ks',
      );
      expect(
        overviewTileFoldId(OverviewGroupBy.machine, 'windows', 'p-ks'),
        'windows/p-ks',
      );
    });
  });

  group('more ways to group', () {
    final start = MissionFixture.now.subtract(const Duration(hours: 3));

    OverviewBoard board(
      MissionFixture fixture,
      OverviewGroupBy by, {
      Set<String> fresh = const {},
    }) => buildOverviewBoard(
      fixture.groups,
      facts: fixture.facts,
      filter: const OverviewFilter(),
      groupBy: by,
      startOfToday: start,
      memo: BoardOrderMemo(),
      fresh: fresh,
    );

    List<String> ids(OverviewLane lane) => [
      for (final column in BoardColumn.values)
        for (final card in [
          ...lane.cards(column),
          if (column == BoardColumn.done) ...lane.doneOlder,
        ])
          card.id,
    ]..sort();

    test('Status files a project whole, under the most urgent of its '
        'sessions', () {
      final fixture = MissionFixture(
        sessions: [
          s('ks-run', 'Runs', state: AgentState.working),
          s('ks-ready', 'Ready', state: AgentState.ready),
          s('beej-new', 'New', project: 'p-beej', state: AgentState.ready),
          s('web-seen', 'Seen', project: 'p-web', state: AgentState.ready),
          s('store-ask', 'Ask', project: 'p-store', state: AgentState.needsYou),
        ],
      );
      final lanes = board(
        fixture,
        OverviewGroupBy.status,
        fresh: {'beej-new'},
      ).lanes;
      expect(
        [for (final lane in lanes) lane.label],
        ['Needs you', 'Running', 'New', 'To go back to'],
      );
      expect(ids(lanes[0]), ['store-ask']);
      expect(ids(lanes[1]), ['ks-ready', 'ks-run']);
      expect(ids(lanes[2]), ['beej-new']);
      expect(ids(lanes[3]), ['web-seen']);
    });

    test('Last active files a project by its newest session', () {
      final fixture = MissionFixture(
        sessions: [
          s('ks-now', 'Now', state: AgentState.working, age: 5),
          s('ks-old', 'Old', age: 60 * 24 * 12),
          s('beej-y', 'Yesterday', project: 'p-beej', age: 60 * 10),
          s('web-w', 'Week', project: 'p-web', age: 60 * 24 * 3),
          s('docs-o', 'Older', project: 'p-docs', age: 60 * 24 * 12),
        ],
      );
      final lanes = board(fixture, OverviewGroupBy.lastActive).lanes;
      expect(
        [for (final lane in lanes) lane.label],
        ['Today', 'Yesterday', 'This week', 'Older'],
      );
      expect(ids(lanes[0]), ['ks-now', 'ks-old']);
      expect(ids(lanes[1]), ['beej-y']);
      expect(ids(lanes[2]), ['web-w']);
      expect(ids(lanes[3]), ['docs-o']);
    });

    test('Agent files a family whole, under its first session\'s agent', () {
      final fixture = MissionFixture(
        sessions: [
          s('root', 'Root', state: AgentState.working),
          (
            id: 'kid',
            title: 'Kid',
            project: 'p-ks',
            machine: 'windows',
            agent: AgentIds.codex,
            state: AgentState.working,
            age: const Duration(minutes: 2),
            parent: 'root',
            report: null,
          ),
          s('other', 'Other', agent: AgentIds.codex, state: AgentState.ready),
        ],
      );
      final lanes = board(fixture, OverviewGroupBy.agent).lanes;
      expect(
        {for (final lane in lanes) lane.key: ids(lane)},
        {
          AgentIds.claudeCode: ['kid', 'root'],
          AgentIds.codex: ['other'],
        },
      );
    });

    testWidgets('Group by, beside the group chips, lists them and changes '
        'the board', (tester) async {
      final c = await pumpMission(
        tester,
        fixture: MissionFixture.full(),
        prefsDir: dir,
        lines: true,
      );
      expect(find.text('Group: None'), findsOneWidget);
      await tester.tap(byKey('overview-group-by'));
      await settleMission(tester);
      // No context exists in this fixture, so Context is not offered.
      expect(byKey('overview-group-by:context'), findsNothing);
      for (final by in [
        'machine',
        'status',
        'agent',
        'lastActive',
        'project',
      ]) {
        expect(byKey('overview-group-by:$by'), findsOneWidget, reason: by);
      }
      await tester.tap(byKey('overview-group-by:status'));
      await settleMission(tester);

      expect(c.read(overviewPrefsProvider).groupBy, OverviewGroupBy.status);
      expect(find.text('Group: Status'), findsOneWidget);
      Finder section(String key) => find.byWidgetPredicate(
        (w) => w is OverviewLaneHeader && w.lane.key == key,
      );
      expect(section('needsYou'), findsOneWidget);
      expect(section('running'), findsOneWidget);
      // karmashala has an ask, so its whole tile is under Needs you.
      expect(
        tester.getTopLeft(tile('p-ks')).dy,
        lessThan(tester.getTopLeft(section('running')).dy),
      );
      expect(tester.takeException(), isNull);
      await unmountMission(tester);
    });
  });

  test('finished sessions are lines unless this device asks for cards, and '
      'the choice is kept', () {
    final c = ProviderContainer(
      overrides: [
        overviewPrefsDirectoryProvider.overrideWithValue(() async => dir),
      ],
    );
    addTearDown(c.dispose);
    expect(c.read(overviewFinishedAsLinesProvider), isTrue);
    c.read(overviewPrefsProvider.notifier).setFinishedAsCards(true);
    expect(c.read(overviewFinishedAsLinesProvider), isFalse);
    final kept = OverviewPrefs.fromJson(c.read(overviewPrefsProvider).toJson());
    expect(kept.finishedAsCards, isTrue);
    expect(
      OverviewPrefs.fromJson(const <String, Object?>{}).finishedAsCards,
      isFalse,
    );
  });

  test('moving a family within its tile keeps the order the group\'s other '
      'tiles were given', () {
    final c = ProviderContainer(
      overrides: [
        overviewPrefsDirectoryProvider.overrideWithValue(() async => dir),
      ],
    );
    addTearDown(c.dispose);
    final order = c.read(overviewFamilyOrderProvider.notifier);
    // One tile's families, then another's, in the same group.
    order.move('windows', ['a', 'b'], 'b', 0);
    order.move('windows', ['x', 'y'], 'y', 0);
    expect(c.read(overviewFamilyOrderProvider)['windows'], [
      'y',
      'x',
      'b',
      'a',
    ]);
    expect(OverviewProjectTile.shownLines, 5);
  });
}
