import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/explorer/application/agent_states.dart';
import 'package:karmashala/src/features/overview/application/overview_family_order.dart';
import 'package:karmashala/src/features/overview/application/overview_links.dart';
import 'package:karmashala/src/features/overview/application/overview_prefs.dart';
import 'package:karmashala/src/features/overview/application/overview_providers.dart';
import 'package:karmashala/src/features/overview/application/overview_search.dart';
import 'package:karmashala/src/features/overview/application/overview_seen.dart';
import 'package:karmashala/src/features/overview/presentation/overview_tab_view.dart';

import 'mission_fixture.dart';

/// **Search and keys on the dashboard**: `/` finds a session wherever it
/// sits — folded, past the cap, done — in a few keys, and the arrows,
/// brackets and U step the board by family, lane and what is new.
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ks-overview-search');
  });
  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } on FileSystemException {
      // The prefs file may still be held open on Windows; the OS sweeps temp.
    }
  });

  MissionSession s(
    String id,
    String title, {
    String project = 'p-ks',
    AgentState state = AgentState.working,
    int age = 5,
    String? parent,
  }) => (
    id: id,
    title: title,
    project: project,
    machine: 'windows',
    agent: AgentIds.claudeCode,
    state: state,
    age: Duration(minutes: age),
    parent: parent,
    report: null,
  );

  MissionFixture fixture() => MissionFixture(
    sessions: [
      s('f-root', 'Folded parent', state: AgentState.ready, age: 90),
      s('f-kid', 'Zebra crossing', parent: 'f-root', age: 80),
      s('c-root', 'Busy parent', age: 70),
      for (var i = 1; i <= 6; i++)
        s(
          'c-k$i',
          i == 6 ? 'Quokka survey' : 'Cap kid $i',
          parent: 'c-root',
          age: 70 - i * 5,
        ),
      s('d-done', 'Xylophone report', state: AgentState.ended, age: 10),
      s('n-ask', 'Asks a question', state: AgentState.needsYou, age: 20),
      s('o-root', 'Other lane', project: 'p-beej', age: 30),
    ],
  );

  Finder byKey(String key) => find.byKey(ValueKey(key));
  final field = find.descendant(
    of: byKey('overview-search'),
    matching: find.byType(EditableText),
  );

  Future<void> key(
    WidgetTester tester,
    LogicalKeyboardKey key, {
    String? character,
  }) async {
    await tester.sendKeyEvent(key, character: character);
    await settleMission(tester);
  }

  Future<void> slash(WidgetTester tester) =>
      key(tester, LogicalKeyboardKey.slash, character: '/');

  bool typing() =>
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<EditableText>() !=
      null;

  String? selected(ProviderContainer c) =>
      c.read(overviewFocusProvider).selected;

  String? peeked(ProviderContainer c) => c.read(overviewFocusProvider).peeked;

  testWidgets('/ reaches a folded sub-session in five keys, unfolding it', (
    tester,
  ) async {
    final c = await pumpMission(tester, fixture: fixture(), prefsDir: dir);
    c.read(overviewFoldedParentsProvider.notifier).toggle('f-root');
    await settleMission(tester);
    expect(byKey('overview-tree-node:f-kid'), findsNothing);

    await slash(tester); // 1
    expect(typing(), isTrue);
    await tester.enterText(field, 'zeb'); // 2, 3, 4
    await settleMission(tester);
    // Only what matches is left on the board, and the first match is the
    // pick: selected, and counted in the field.
    expect(familyCard('o-root'), findsNothing);
    expect(familyCard('f-root'), findsOneWidget);
    expect(byKey('overview-tree-node:f-kid'), findsOneWidget);
    expect(selected(c), 'f-kid');
    expect(find.text('1 of 1'), findsOneWidget);

    await key(tester, LogicalKeyboardKey.enter); // 5
    // Enter opens the pick: the board is whole again, on that session.
    expect(selected(c), 'f-kid');
    expect(peeked(c), 'f-kid');
    expect(c.read(overviewFoldedParentsProvider), isNot(contains('f-root')));
    expect(byKey('overview-tree-node:f-kid'), findsOneWidget);
    expect(typing(), isFalse);
    expect(c.read(overviewSearchProvider).query, isEmpty);
    expect(familyCard('o-root'), findsOneWidget);
    await unmountMission(tester);
  });

  testWidgets('/ reaches a done session, and one past the cap, in five keys', (
    tester,
  ) async {
    final c = await pumpMission(tester, fixture: fixture(), prefsDir: dir);
    expect(byKey('overview-tree-node:c-k6'), findsNothing);

    await slash(tester);
    await tester.enterText(field, 'xyl');
    await key(tester, LogicalKeyboardKey.enter);
    expect(selected(c), 'd-done');

    await slash(tester);
    await tester.enterText(field, 'quo');
    await settleMission(tester);
    // The capped family opens to show the match.
    expect(byKey('overview-tree-node:c-k6'), findsOneWidget);
    await key(tester, LogicalKeyboardKey.enter);
    expect(selected(c), 'c-k6');
    expect(byKey('overview-tree-node:c-k6'), findsOneWidget);
    await unmountMission(tester);
  });

  testWidgets('↑ and ↓ step through the matches; Esc clears in the field', (
    tester,
  ) async {
    final c = await pumpMission(tester, fixture: fixture(), prefsDir: dir);
    await slash(tester);
    await tester.enterText(field, 'cap kid');
    await settleMission(tester);
    // The first match is the pick before any arrow is pressed.
    expect(selected(c), 'c-k1');
    expect(find.text('1 of 5'), findsOneWidget);
    await key(tester, LogicalKeyboardKey.arrowDown);
    expect(selected(c), 'c-k2');
    expect(find.text('2 of 5'), findsOneWidget);
    await key(tester, LogicalKeyboardKey.arrowUp);
    expect(selected(c), 'c-k1');
    // The ends stop: nothing wraps round to the other end.
    await key(tester, LogicalKeyboardKey.arrowUp);
    expect(selected(c), 'c-k1');
    expect(typing(), isTrue);
    await key(tester, LogicalKeyboardKey.escape);
    expect(c.read(overviewSearchProvider).query, isEmpty);
    expect(tester.widget<EditableText>(field).controller.text, isEmpty);
    expect(typing(), isFalse);
    await unmountMission(tester);
  });

  testWidgets('a project name finds its sessions, and no match says so', (
    tester,
  ) async {
    final c = await pumpMission(tester, fixture: fixture(), prefsDir: dir);
    await slash(tester);
    await tester.enterText(field, 'beej');
    await settleMission(tester);
    expect(familyCard('o-root'), findsOneWidget);
    expect(familyCard('c-root'), findsNothing);
    expect(selected(c), 'o-root');

    await tester.enterText(field, 'no such thing');
    await settleMission(tester);
    expect(byKey('overview-none-match'), findsOneWidget);
    expect(find.text('No match'), findsOneWidget);
    await key(tester, LogicalKeyboardKey.enter);
    expect(peeked(c), isNull);
    await key(tester, LogicalKeyboardKey.escape);
    expect(familyCard('c-root'), findsOneWidget);
    await unmountMission(tester);
  });

  testWidgets('it finds only what the dashboard shows: not past the filters, '
      'not what ended before today, not a project with no session', (
    tester,
  ) async {
    final c = await pumpMission(
      tester,
      fixture: MissionFixture(
        sessions: [
          ...fixture().sessions,
          s('old', 'Yak shaving', state: AgentState.ended, age: 60 * 24 * 3),
        ],
      ),
      prefsDir: dir,
    );
    // Only beej is shown, and what ended days ago is not on the board.
    c.read(overviewPrefsProvider.notifier).setProjects({'p-beej'});
    await settleMission(tester);
    expect(familyCard('c-root'), findsNothing);
    expect(familyCard('old'), findsNothing);

    await slash(tester);
    // Filtered out: quick open finds it, not the dashboard.
    await tester.enterText(field, 'busy parent');
    await settleMission(tester);
    expect(familyCard('c-root'), findsNothing);
    expect(find.text('No match'), findsOneWidget);
    expect(byKey('overview-none-match'), findsOneWidget);

    await tester.enterText(field, 'yak');
    await settleMission(tester);
    expect(familyCard('old'), findsNothing);
    expect(find.text('No match'), findsOneWidget);

    await tester.enterText(field, 'docs');
    await settleMission(tester);
    expect(byKey('overview-tile:p-docs'), findsNothing);
    expect(find.text('No match'), findsOneWidget);

    // Cleared, the board is as it was.
    await key(tester, LogicalKeyboardKey.escape);
    expect(familyCard('c-root'), findsNothing);
    expect(familyCard('o-root'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await unmountMission(tester);
  });

  testWidgets('empty and focused, it lists what needs you, then what is new', (
    tester,
  ) async {
    final c = await pumpMission(tester, fixture: fixture(), prefsDir: dir);
    await tester.runAsync(() async {
      for (var i = 0; i < 100 && !c.read(overviewSeenReadProvider); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await settleMission(tester);
    await slash(tester);
    expect(byKey('overview-search-list'), findsOneWidget);
    final ask = byKey('overview-search-hint:Needs you:n-ask');
    final fresh = byKey('overview-search-hint:New:f-root');
    expect(ask, findsOneWidget);
    expect(fresh, findsOneWidget);
    expect(tester.getTopLeft(ask).dy, lessThan(tester.getTopLeft(fresh).dy));
    expect(find.text('NEEDS YOU'), findsOneWidget);
    await key(tester, LogicalKeyboardKey.enter);
    expect(selected(c), 'n-ask');
    expect(byKey('overview-search-list'), findsNothing);
    await unmountMission(tester);
  });

  testWidgets('← → step by project tile, [ ] by group, U to what is new', (
    tester,
  ) async {
    final c = await pumpMission(tester, fixture: fixture(), prefsDir: dir);
    await tester.runAsync(() async {
      for (var i = 0; i < 100 && !c.read(overviewSeenReadProvider); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await settleMission(tester);
    final forest = c.read(overviewForestProvider);
    final roots = [
      for (final (_, trees) in forest.lanes)
        for (final tree in trees) tree.card.id,
    ];
    expect(roots.length, greaterThan(2));
    expect(forest.lanes.length, 2);

    // Each project is a tile: the arrows land on a tile's first session.
    final firstOf = [
      for (final (_, trees) in forest.lanes) trees.first.card.id,
    ];
    await key(tester, LogicalKeyboardKey.arrowRight);
    expect(selected(c), firstOf[0]);
    await key(tester, LogicalKeyboardKey.arrowRight);
    expect(selected(c), firstOf[1]);
    await key(tester, LogicalKeyboardKey.arrowRight);
    expect(selected(c), firstOf[1], reason: 'the last tile is the end');
    await key(tester, LogicalKeyboardKey.arrowLeft);
    expect(selected(c), firstOf[0]);

    await key(tester, LogicalKeyboardKey.bracketRight, character: ']');
    expect(selected(c), firstOf[1]);
    await key(tester, LogicalKeyboardKey.bracketLeft, character: '[');
    expect(selected(c), firstOf[0]);

    // Everything but the first is seen: U goes to it from anywhere.
    final members = overviewForestMembers(forest).toList();
    final seen = c.read(overviewSeenProvider.notifier);
    for (final card in members.skip(1)) {
      seen.markSeen(card.id, MissionFixture.now);
    }
    await settleMission(tester);
    c.read(overviewFocusProvider.notifier).select(members.last.id);
    await key(tester, LogicalKeyboardKey.keyU);
    expect(selected(c), members.first.id);
    await unmountMission(tester);
  });

  testWidgets('J and K walk every drawn session, done ones included', (
    tester,
  ) async {
    final c = await pumpMission(tester, fixture: fixture(), prefsDir: dir);
    final walked = <String>{};
    for (var i = 0; i < 20; i++) {
      await key(tester, LogicalKeyboardKey.keyJ);
      walked.add(selected(c)!);
    }
    expect(walked, containsAll(['d-done', 'f-kid', 'o-root', 'n-ask']));
    await unmountMission(tester);
  });

  testWidgets('a session asked for before the board is up is shown once it '
      'is: unfolded, selected and scrolled to', (tester) async {
    final onDashboard = ValueNotifier(false);
    addTearDown(onDashboard.dispose);
    final c = await pumpMission(
      tester,
      fixture: fixture(),
      prefsDir: dir,
      size: const Size(900, 500),
      home: ValueListenableBuilder(
        valueListenable: onDashboard,
        builder: (context, on, _) => on
            ? const OverviewTabView()
            : const Scaffold(body: Text('another tab')),
      ),
    );
    c.read(overviewFoldedParentsProvider.notifier).toggle('c-root');
    // As quick open's Show on dashboard asks, from another tab.
    c.read(overviewRevealProvider.notifier).reveal('c-k6');
    onDashboard.value = true;
    await settleMission(tester);
    await settleMission(tester);

    expect(selected(c), 'c-k6');
    expect(c.read(overviewFoldedParentsProvider), isEmpty);
    expect(c.read(overviewRevealProvider), isNull);
    final pill = byKey('overview-tree-node:c-k6');
    expect(pill, findsOneWidget);
    final view = tester.getRect(byKey('overview-hybrid'));
    expect(view.contains(tester.getCenter(pill)), isTrue);
    await unmountMission(tester);
  });
}
