import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/explorer/application/agent_states.dart';
import 'package:karmashala/src/features/overview/application/overview_reads.dart';
import 'package:karmashala/src/features/overview/application/overview_seen.dart';
import 'package:karmashala/src/features/overview/presentation/overview_tab_view.dart';

import 'mission_fixture.dart';

/// Holds the dashboard, or another tab in its place, as the workbench does
/// when the owner switches tabs.
class _Tabs extends StatelessWidget {
  const _Tabs(this.onDashboard);

  final ValueNotifier<bool> onDashboard;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: onDashboard,
    builder: (context, on, _) => on
        ? const OverviewTabView()
        : const Scaffold(body: Text('another tab')),
  );
}

/// **What is new stays new until it is opened**: a session never opened here
/// is new, leaving the dashboard clears nothing, and Mark seen marks it.
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ks-overview-unread');
  });
  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } on FileSystemException {
      // The prefs file may still be held open on Windows; the OS sweeps temp.
    }
  });

  MissionSession session(String id, String title, {Duration? age}) => (
    id: id,
    title: title,
    project: 'p-ks',
    machine: 'windows',
    agent: AgentIds.claudeCode,
    state: AgentState.ready,
    age: age ?? const Duration(minutes: 30),
    parent: null,
    report: null,
  );

  final now = MissionFixture.now;
  MissionFixture fixture() => MissionFixture(
    sessions: [
      session('u-never', 'Never opened'),
      session('u-read', 'Opened and read'),
      session('u-more', 'Opened, then more came'),
    ],
    glances: {
      for (final id in ['u-never', 'u-read', 'u-more'])
        id: OverviewGlance(
          messageTimes: [
            for (final m in [20, 10]) now.subtract(Duration(minutes: m)),
          ],
        ),
    },
  );

  Finder badge(String id) => find.byKey(ValueKey('overview-new:$id'));
  Finder badgeSays(String id, String text) =>
      find.descendant(of: badge(id), matching: find.text(text));

  /// Lets the looks kept on disk be read, which real IO does off the fake
  /// clock.
  Future<void> readKept(WidgetTester tester, ProviderContainer c) async {
    await tester.runAsync(() async {
      for (var i = 0; i < 100 && !c.read(overviewSeenReadProvider); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await settleMission(tester);
  }

  testWidgets('a session never opened here shows as new', (tester) async {
    final c = await pumpMission(tester, fixture: fixture(), prefsDir: dir);
    await readKept(tester, c);
    expect(c.read(overviewSeenReadProvider), isTrue);
    expect(badgeSays('u-never', 'New'), findsOneWidget);
    expect(find.byTooltip('Never opened here'), findsWidgets);
    await unmountMission(tester);
  });

  testWidgets('leaving the dashboard and coming back clears nothing', (
    tester,
  ) async {
    final onDashboard = ValueNotifier(true);
    addTearDown(onDashboard.dispose);
    final c = await pumpMission(
      tester,
      fixture: fixture(),
      prefsDir: dir,
      home: _Tabs(onDashboard),
    );
    await readKept(tester, c);
    final seen = c.read(overviewSeenProvider.notifier);
    seen.markSeen('u-read', now);
    seen.markSeen('u-more', now.subtract(const Duration(minutes: 15)));
    await settleMission(tester);
    expect(badgeSays('u-never', 'New'), findsOneWidget);
    expect(badge('u-read'), findsNothing);
    expect(badgeSays('u-more', '1'), findsOneWidget);

    onDashboard.value = false;
    await settleMission(tester);
    expect(find.text('another tab'), findsOneWidget);
    expect(badge('u-never'), findsNothing);
    onDashboard.value = true;
    await settleMission(tester);

    expect(badgeSays('u-never', 'New'), findsOneWidget);
    expect(badgeSays('u-more', '1'), findsOneWidget);
    expect(c.read(overviewSeenProvider).containsKey('u-never'), isFalse);
    await unmountMission(tester);
  });

  testWidgets('Mark seen in the menu marks it seen', (tester) async {
    final c = await pumpMission(tester, fixture: fixture(), prefsDir: dir);
    await readKept(tester, c);
    expect(badgeSays('u-never', 'New'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('overview-card-menu:u-never')));
    await settleMission(tester);
    await tester.tap(find.byKey(const ValueKey('overview-card-menu:seen')));
    await settleMission(tester);
    expect(badge('u-never'), findsNothing);
    expect(c.read(overviewSeenProvider).containsKey('u-never'), isTrue);
    await unmountMission(tester);
  });

  testWidgets('opening it in the peek marks it seen', (tester) async {
    final c = await pumpMission(tester, fixture: fixture(), prefsDir: dir);
    await readKept(tester, c);
    await tester.tap(
      find.byKey(const ValueKey('overview-family-open:u-never')),
    );
    await settleMission(tester);
    expect(c.read(overviewSeenProvider).containsKey('u-never'), isTrue);
    await unmountMission(tester);
  });
}
