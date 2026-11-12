import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/overview/presentation/overview_tab_view.dart';
import 'package:karmashala/src/features/overview/presentation/overview_triage.dart';

import 'mission_fixture.dart';

/// **The dashboard holds the keys while it is on screen** (owner, 2026-11-12:
/// after switching to it, the keys worked only once the board was clicked).
/// The workbench gives the keyboard to the pane around a tab when the tab is
/// shown; the board's keys live under that, so it takes them on from there.
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ks-overview-focus');
  });
  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } on FileSystemException {
      // The prefs file may still be held open on Windows; the OS sweeps temp.
    }
  });

  testWidgets(
    'keys work when the pane around the board is given the keyboard',
    (tester) async {
      final pane = FocusNode(debugLabel: 'document pane', skipTraversal: true);
      addTearDown(pane.dispose);
      await pumpMission(
        tester,
        fixture: MissionFixture.full(),
        prefsDir: dir,
        home: Scaffold(
          body: Focus(focusNode: pane, child: const OverviewTabView()),
        ),
      );
      // As the workbench does once the tab is on screen.
      pane.requestFocus();
      await settleMission(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.slash, character: '?');
      await settleMission(tester);
      expect(find.byType(OverviewKeysSheet), findsOneWidget);
      await unmountMission(tester);
    },
  );

  testWidgets('a text field around the board keeps the keyboard', (
    tester,
  ) async {
    final field = FocusNode();
    addTearDown(field.dispose);
    await pumpMission(
      tester,
      fixture: MissionFixture.full(),
      prefsDir: dir,
      home: Scaffold(
        body: Column(
          children: [
            TextField(focusNode: field),
            const Expanded(child: OverviewTabView()),
          ],
        ),
      ),
    );
    field.requestFocus();
    await settleMission(tester);
    expect(field.hasPrimaryFocus, isTrue);
    await unmountMission(tester);
  });
}
