import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/explorer/application/agent_states.dart';
import 'package:karmashala/src/features/overview/application/overview_board.dart';
import 'package:karmashala/src/features/overview/application/overview_prefs.dart';
import 'package:karmashala/src/features/sessions/application/session_list_prefs.dart';

import 'mission_fixture.dart';

/// **Mission control over a realistic workspace**: tiles by attention, the
/// sub-session dots and "+N", what every mark and counter says to a screen
/// reader, the calm state, Hide while working, and no overflow at the
/// desktop and phone sizes or at 1.6× text.
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ks-mission');
  });
  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } on FileSystemException {
      // The prefs file may still be held open on Windows; the OS sweeps temp.
    }
  });

  Finder tile(String key) => find.byKey(ValueKey('overview-lane:$key'));
  Finder mark(String lane, String id) =>
      find.byKey(ValueKey('overview:$lane:$id'));

  testWidgets('tiles run by attention: needs you, working, then recent', (
    tester,
  ) async {
    await pumpMission(tester, fixture: MissionFixture(), prefsDir: dir);

    final order = [
      'p-ks',
      'p-store',
      'p-beej',
      'p-relay',
      'p-web',
      'p-docs',
    ].map((k) => tester.getTopLeft(tile(k))).toList();
    // Reading order: rows top to bottom, tiles left to right.
    for (var i = 1; i < order.length; i++) {
      final before = order[i - 1], after = order[i];
      expect(
        after.dy > before.dy || (after.dy == before.dy && after.dx > before.dx),
        isTrue,
        reason: 'tile $i is drawn before tile ${i - 1}',
      );
    }
    expect(find.text('3 quiet projects'), findsOneWidget);
    expect(tile('p-legacy'), findsNothing);
    await tester.tap(find.text('3 quiet projects'));
    await settleMission(tester);
    final quiet = find.byKey(const ValueKey('overview-quiet-tile:p-legacy'));
    await tester.dragUntilVisible(
      quiet,
      find.byKey(const ValueKey('overview-mission')),
      const Offset(0, -200),
    );
    expect(quiet, findsOneWidget);
    await unmountMission(tester);
  });

  testWidgets("a parent's sub-sessions are dots under its mark", (
    tester,
  ) async {
    await pumpMission(tester, fixture: MissionFixture(), prefsDir: dir);

    final dots = find.descendant(
      of: mark('p-ks', 'ks-r32'),
      matching: find.byKey(const ValueKey('overview-mark-dots')),
    );
    expect(dots, findsOneWidget);
    expect(
      find.descendant(of: dots, matching: find.text('+2')),
      findsOneWidget,
    );
    // Stacked on the parent, not marks of their own.
    expect(mark('p-ks', 'ks-r32-sub0'), findsNothing);
    await unmountMission(tester);
  });

  testWidgets('a crowded tile caps its marks with "+N", which shows them all', (
    tester,
  ) async {
    final crowded = [
      for (var i = 0; i < 16; i++)
        (
          id: 'c$i',
          title: 'Chat $i',
          project: 'p-ks',
          machine: 'windows',
          agent: 'claudeCode',
          state: AgentState.ready,
          age: Duration(minutes: i),
          parent: null,
          report: null,
        ),
    ];
    await pumpMission(
      tester,
      fixture: MissionFixture(sessions: crowded),
      prefsDir: dir,
      size: const Size(390, 844),
      phone: true,
    );

    final more = find.byKey(const ValueKey('overview-more:p-ks'));
    expect(more, findsOneWidget);
    expect(mark('p-ks', 'c15'), findsNothing);
    await tester.tap(more);
    await settleMission(tester);
    expect(more, findsNothing);
    expect(mark('p-ks', 'c15'), findsOneWidget);
    await unmountMission(tester);
  });

  testWidgets('every mark and counter says what it is', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpMission(tester, fixture: MissionFixture(), prefsDir: dir);

    expect(
      find.bySemanticsLabel(
        RegExp(
          r'^Needs you, Round 21 · ACP sessions, Claude Code, '
          r'Asks to run a command',
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(
        RegExp(r'^Working, Round 32 · Overview redesign, .*sub-sessions 5'),
      ),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(RegExp(r'^Needs you, 2, oldest 12m · 1 failed')),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel(RegExp(r'^Working, 9, ')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^Ready, 6, ')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^Done today, 4, ')), findsOneWidget);
    expect(
      find.bySemanticsLabel(RegExp(r'^Most urgent: Needs you, Round 21')),
      findsOneWidget,
    );
    handle.dispose();
    await unmountMission(tester);
  });

  testWidgets('by machine, a session names its project', (tester) async {
    final c = await pumpMission(
      tester,
      fixture: MissionFixture(),
      prefsDir: dir,
    );
    final handle = tester.ensureSemantics();
    c.read(overviewPrefsProvider.notifier).setGroupBy(OverviewGroupBy.machine);
    await settleMission(tester);

    expect(tile('wsl:arch'), findsOneWidget);
    expect(
      find.bySemanticsLabel(
        RegExp(r'^Working, Release 1\.34 prep, .*in karmashala'),
      ),
      findsOneWidget,
    );
    handle.dispose();
    await unmountMission(tester);
  });

  testWidgets('nothing live: one calm line and what finished today', (
    tester,
  ) async {
    final c = await pumpMission(
      tester,
      fixture: MissionFixture(
        sessions: [
          for (final s in MissionFixture.realisticSessions())
            if (s.state == AgentState.ended && s.parent == null) s,
        ],
      ),
      prefsDir: dir,
      size: const Size(390, 844),
      phone: true,
    );

    expect(find.byKey(const ValueKey('overview-calm')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('overview-counter:needsYou')),
      findsNothing,
    );
    expect(find.text('4 done today'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('overview-calm-done')));
    await settleMission(tester);
    expect(c.read(overviewPrefsProvider).filter.columns, {BoardColumn.done});
    expect(
      find.byKey(const ValueKey('overview-counter:needsYou')),
      findsOneWidget,
    );
    await unmountMission(tester);
  });

  testWidgets('Hide while working leaves "N hidden · Show" on Working', (
    tester,
  ) async {
    final c = await pumpMission(
      tester,
      fixture: MissionFixture(hiddenWorking: 3),
      prefsDir: dir,
    );
    c.read(sessionListPrefsProvider.notifier).setHideWorking(true);
    await settleMission(tester);

    expect(find.text('3 hidden · Show'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('overview-working-hidden')));
    await settleMission(tester);
    expect(c.read(sessionListPrefsProvider).hideWorking, isFalse);
    await unmountMission(tester);
  });

  for (final (name, size, phone) in [
    ('1440×900', const Size(1440, 900), false),
    ('1024×768', const Size(1024, 768), false),
    ('390×844', const Size(390, 844), true),
    ('360×640', const Size(360, 640), true),
  ]) {
    for (final scale in [1.0, 1.6]) {
      testWidgets('$name at ${scale}x text draws without overflow', (
        tester,
      ) async {
        await pumpMission(
          tester,
          fixture: MissionFixture(),
          prefsDir: dir,
          size: size,
          phone: phone,
          textScale: scale,
        );
        expect(tester.takeException(), isNull);
        // And the far end of the list, scrolled to.
        await tester.drag(
          find.byKey(const ValueKey('overview-mission')),
          const Offset(0, -4000),
        );
        await settleMission(tester);
        expect(tester.takeException(), isNull);
        await unmountMission(tester);
      });
    }
  }
}
