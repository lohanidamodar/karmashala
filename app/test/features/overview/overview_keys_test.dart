import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/overview/presentation/overview_triage.dart';
import 'package:karmashala_ui/theme.dart';

import 'mission_fixture.dart';

/// **The dashboard's keys, discoverable**: the sheet is built from the
/// board's own bindings, so a key bound is a key listed; it opens from a
/// keyboard button in the header, from ?, and is hidden under a thumb.
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ks-overview-keys');
  });
  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } on FileSystemException {
      // The prefs file may still be held open on Windows; the OS sweeps temp.
    }
  });

  Finder byKey(String key) => find.byKey(ValueKey(key));

  test('every key the board binds says what it does', () {
    for (final MapEntry(key: activator, value: intent)
        in overviewTriageShortcuts.entries) {
      expect(
        describeOverviewIntent(intent),
        isNotNull,
        reason: '${activator.debugDescribeKeys()} → ${intent.runtimeType}',
      );
    }
  });

  test('every binding is on a row of the sheet, with its keycap', () {
    final rows = overviewBoundKeyRows();
    for (final MapEntry(key: activator, value: intent)
        in overviewTriageShortcuts.entries) {
      final does = describeOverviewIntent(intent)!.does;
      final row = rows.singleWhere((r) => r.does == does);
      expect(row.keys, contains(overviewKeyCap(activator, intent)));
      expect(kOverviewKeyGroups, contains(row.group));
    }
    // Eighteen digit bindings read as one cap; Enter and keypad Enter as one.
    final pick = rows.singleWhere((r) => r.keys.contains('1–9'));
    expect(pick.keys, ['1–9']);
    final send = rows.singleWhere((r) => r.does.startsWith('Send the picked'));
    expect(send.keys, ['Enter']);
    expect(rows.singleWhere((r) => r.does == 'Next session').keys, ['↓', 'J']);
  });

  test('a key bound later is listed without editing the list', () {
    final rows = overviewBoundKeyRows({
      ...overviewTriageShortcuts,
      const SingleActivator(LogicalKeyboardKey.keyW, control: true):
          const OverviewNextWaitingIntent(),
    });
    expect(
      rows.singleWhere((r) => r.does.startsWith('Next item waiting')).keys,
      ['N', 'Ctrl W'],
    );
  });

  testWidgets('the sheet draws every row as keycaps beside its words', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: const Scaffold(
          body: SingleChildScrollView(child: OverviewKeysSheet()),
        ),
      ),
    );
    for (final row in overviewKeyRows()) {
      final line = byKey('overview-key:${row.does}');
      expect(line, findsOneWidget, reason: row.does);
      for (final key in row.keys) {
        expect(
          find.descendant(of: line, matching: find.text(key)),
          findsOneWidget,
          reason: '${row.does}: $key',
        );
      }
    }
    for (final group in kOverviewKeyGroups) {
      expect(find.text(group.toUpperCase()), findsOneWidget);
    }
  });

  group('the way in', () {
    testWidgets('a keyboard button in the header opens the keys', (
      tester,
    ) async {
      await pumpMission(tester, fixture: MissionFixture.full(), prefsDir: dir);
      expect(find.byTooltip('Keyboard shortcuts (?)'), findsOneWidget);
      await tester.tap(byKey('overview-keys-button'));
      await settleMission(tester);
      expect(byKey('overview-keys'), findsOneWidget);
      expect(find.text(kOverviewKeysTitle), findsOneWidget);
      // A dialog on a desktop.
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settleMission(tester);
      expect(byKey('overview-keys'), findsNothing);
      await unmountMission(tester);
    });

    testWidgets('under a thumb there is no button, and none is needed', (
      tester,
    ) async {
      await pumpMission(
        tester,
        fixture: MissionFixture.full(),
        prefsDir: dir,
        size: const Size(390, 844),
        phone: true,
      );
      expect(byKey('overview-keys-button'), findsNothing);
      expect(byKey('overview-filter-button'), findsOneWidget);
      await unmountMission(tester);
    });

    for (final (name, size) in [
      ('360', const Size(360, 640)),
      ('1440', const Size(1440, 900)),
    ]) {
      for (final scale in [1.0, 1.6]) {
        testWidgets('$name px at ${scale}x text: the sheet fits', (
          tester,
        ) async {
          await pumpMission(
            tester,
            fixture: MissionFixture.full(),
            prefsDir: dir,
            size: size,
            textScale: scale,
          );
          await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
          await tester.sendKeyEvent(LogicalKeyboardKey.slash, character: '?');
          await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
          await settleMission(tester);
          expect(byKey('overview-keys'), findsOneWidget);
          // A sheet on a narrow window, a dialog on a wide one.
          expect(
            find.byType(BottomSheet),
            size.width < 600 ? findsOneWidget : findsNothing,
          );
          expect(tester.takeException(), isNull);
          await unmountMission(tester);
        });
      }
    }
  });
}
