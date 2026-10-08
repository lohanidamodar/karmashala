import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/phone_shell.dart';
import 'package:karmashala/src/features/explorer/application/agent_states.dart';
import 'package:karmashala/src/features/explorer/presentation/agents_lens.dart';
import 'package:karmashala/src/features/overview/application/overview_prefs.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';

import '../../features/overview/mission_fixture.dart';

/// **The Dashboard is the phone's home** (owner, 2026-10-08): the first tab
/// and where the app opens, Sessions under More and a tap from the board, a
/// session picked anywhere still opening its page; its header one compact
/// row and its triage one line.
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ks-phone-home');
  });
  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } on FileSystemException {
      // The prefs file may still be held open on Windows; the OS sweeps temp.
    }
  });

  Finder byKey(String key) => find.byKey(ValueKey(key));

  Future<dynamic> pumpShell(WidgetTester tester) => pumpMission(
    tester,
    fixture: MissionFixture.full(),
    prefsDir: dir,
    size: const Size(390, 844),
    phone: true,
    home: const PhoneShell(),
  );

  List<String> barLabels(WidgetTester tester) => [
    for (final destination in tester.widgetList<NavigationDestination>(
      find.byType(NavigationDestination),
    ))
      destination.label,
  ];

  group('the phone shell', () {
    testWidgets('Dashboard is the first tab, and Sessions is not one', (
      tester,
    ) async {
      await pumpShell(tester);
      expect(barLabels(tester), [
        'Dashboard',
        'Projects',
        'Terminals',
        'Inbox',
        'More',
      ]);
      await unmountMission(tester);
    });

    testWidgets('it opens on the Dashboard', (tester) async {
      final c = await pumpShell(tester);
      expect(c.read(phoneTabProvider), PhoneTab.dashboard);
      expect(byKey('overview-hybrid'), findsOneWidget);
      // A root tab: no page title or back arrow over it.
      expect(find.byType(BackButton), findsNothing);
      expect(find.text('Agent dashboard'), findsNothing);
      await unmountMission(tester);
    });

    testWidgets('Sessions is under More', (tester) async {
      final c = await pumpShell(tester);
      await tester.tap(find.text('More'));
      await settleMission(tester);
      await tester.tap(find.widgetWithText(ListTile, 'Sessions'));
      await settleMission(tester);
      expect(c.read(phoneTabProvider), PhoneTab.more);
      expect(find.byType(AgentsPage), findsOneWidget);
      await unmountMission(tester);
    });

    testWidgets('and a tap from the end of the board', (tester) async {
      final c = await pumpShell(tester);
      await tester.scrollUntilVisible(
        byKey('overview-all-sessions'),
        400,
        scrollable: hybridList,
      );
      await tester.tap(byKey('overview-all-sessions'));
      await settleMission(tester);
      expect(c.read(phoneTabProvider), PhoneTab.more);
      expect(find.byType(AgentsPage), findsOneWidget);
      await unmountMission(tester);
    });

    testWidgets('a session picked from outside still opens its page', (
      tester,
    ) async {
      final c = await pumpShell(tester);
      // What a notification or a deep link does: select the session.
      c.read(selectedSessionIdProvider.notifier).select('ks-r32');
      await tester.pump();
      expect(c.read(phoneWorkbenchProvider), isTrue);
      await unmountMission(tester);
    });
  });

  group('the Dashboard on a phone', () {
    for (final width in [360.0, 390.0, 412.0]) {
      for (final scale in [1.0, 1.6]) {
        testWidgets('${width}px at ${scale}x: the header is one row', (
          tester,
        ) async {
          await pumpMission(
            tester,
            fixture: MissionFixture.full(),
            prefsDir: dir,
            size: Size(width, 800),
            phone: true,
            textScale: scale,
          );
          final segment = tester.getRect(byKey('overview-view'));
          final filter = tester.getRect(byKey('overview-filter-button'));
          final resume = tester.getRect(byKey('overview-resume'));
          // Side by side: their rows overlap, nothing wrapped under another.
          expect(filter.top, lessThan(segment.bottom));
          expect(resume.top, lessThan(segment.bottom));
          expect(segment.right, lessThanOrEqualTo(resume.left));
          expect(byKey('overview-keys-button'), findsNothing);
          expect(tester.takeException(), isNull);
          await unmountMission(tester);
        });
      }
    }

    testWidgets('the triage line shows only what has something in it', (
      tester,
    ) async {
      final c = await pumpMission(
        tester,
        fixture: MissionFixture.full(),
        prefsDir: dir,
        size: const Size(390, 800),
        phone: true,
      );
      // karmashala alone: nothing failed there.
      c.read(overviewPrefsProvider.notifier).setProjects({'p-ks'});
      await settleMission(tester);
      expect(byKey('overview-counter:working'), findsOneWidget);
      expect(byKey('overview-counter:failed'), findsNothing);
      // One line: a chip's height, not two.
      expect(
        tester.getSize(byKey('overview-triage-line')).height,
        lessThanOrEqualTo(
          tester.getSize(byKey('overview-counter:working')).height,
        ),
      );
      // Done is said once, by the fold that opens it.
      expect(byKey('overview-counter:done'), findsNothing);
      await tester.scrollUntilVisible(
        byKey('overview-done-fold'),
        300,
        scrollable: hybridList,
      );
      expect(byKey('overview-done-fold'), findsOneWidget);
      await unmountMission(tester);
    });

    testWidgets('all clear when nothing is in any bucket', (tester) async {
      await pumpMission(
        tester,
        fixture: MissionFixture(
          sessions: [
            for (final s in MissionFixture.realisticSessions())
              if (s.state == AgentState.ended) s,
          ],
        ),
        prefsDir: dir,
        size: const Size(360, 800),
        phone: true,
      );
      expect(byKey('overview-all-clear'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('overview-counter:working')),
        findsNothing,
      );
      await unmountMission(tester);
    });

    testWidgets('a desktop keeps every counter', (tester) async {
      await pumpMission(tester, fixture: MissionFixture.full(), prefsDir: dir);
      expect(byKey('overview-counter:done'), findsOneWidget);
      expect(byKey('overview-all-clear'), findsNothing);
      await unmountMission(tester);
    });
  });
}
