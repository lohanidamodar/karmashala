import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/overview/application/overview_drawer.dart';
import 'package:karmashala/src/features/overview/application/overview_providers.dart';
import 'package:karmashala/src/features/overview/application/overview_search.dart';
import 'package:karmashala/src/features/overview/application/overview_seen.dart';
import 'package:karmashala_ui/tokens.dart';

import 'mission_fixture.dart';

/// **The phone dashboard's bottom bar** (round 118): Search, Waiting N,
/// Next new and Lanes under the thumb; the strip keeps only the counts and
/// More, and the board's gutters are a phone's.
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ks-phone-bar');
  });
  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } on FileSystemException {
      // The prefs file may still be held open on Windows; the OS sweeps temp.
    }
  });

  Finder byKey(String key) => find.byKey(ValueKey(key));

  const items = [
    'overview-bar-search',
    'overview-bar-waiting',
    'overview-bar-next-new',
    'overview-bar-lanes',
  ];

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    Size size = const Size(390, 844),
    double scale = 1,
  }) async {
    final c = await pumpMission(
      tester,
      fixture: MissionFixture.full(),
      prefsDir: dir,
      size: size,
      phone: size.width < WidthClass.mediumMin,
      textScale: scale,
    );
    // The looks kept on disk are read off the fake clock; until then
    // nothing counts as new.
    await tester.runAsync(() async {
      for (var i = 0; i < 100 && !c.read(overviewSeenReadProvider); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await settleMission(tester);
    return c;
  }

  testWidgets('a phone has the bar, and the strip leaves it what it holds', (
    tester,
  ) async {
    await pump(tester);
    for (final key in items) {
      expect(byKey(key), findsOneWidget, reason: key);
    }
    for (final key in [
      'overview-search',
      'overview-strip-new',
      'overview-strip-pinned',
      'overview-waiting-toggle',
    ]) {
      expect(byKey(key), findsNothing, reason: key);
    }
    expect(byKey('overview-more-toggle'), findsOneWidget);
    expect(byKey('overview-lane-chips'), findsOneWidget);
    // The bar sits at the bottom of the dashboard, across it.
    final bar = tester.getRect(byKey('overview-phone-bar'));
    expect(bar.width, 390);
    expect(bar.bottom, lessThanOrEqualTo(844));
    await unmountMission(tester);
  });

  testWidgets('wide, there is no bar and the strip keeps its controls', (
    tester,
  ) async {
    await pump(tester, size: const Size(1440, 900));
    expect(byKey('overview-phone-bar'), findsNothing);
    for (final key in [
      'overview-search',
      'overview-strip-new',
      'overview-strip-pinned',
      'overview-waiting-toggle',
    ]) {
      expect(byKey(key), findsOneWidget, reason: key);
    }
    await unmountMission(tester);
  });

  testWidgets('each item is a thumb\'s target with a compact face', (
    tester,
  ) async {
    await pump(tester);
    for (final key in items) {
      final hit = tester.getSize(byKey(key));
      expect(hit.height, greaterThanOrEqualTo(Touch.target), reason: key);
      expect(hit.width, greaterThanOrEqualTo(Touch.target), reason: key);
      final glyph = tester.getSize(
        find.descendant(of: byKey(key), matching: find.byType(Icon)),
      );
      expect(glyph.height, lessThanOrEqualTo(Touch.icon), reason: key);
    }
    await unmountMission(tester);
  });

  testWidgets('the families sit a phone\'s gutter from the edge', (
    tester,
  ) async {
    await pump(tester);
    expect(tester.getTopLeft(familyCard('ks-r21')).dx, Insets.sm);
    await unmountMission(tester);
  });

  testWidgets('Waiting counts the asks and opens the drawer as a bottom '
      'sheet over the board, above the bar', (tester) async {
    final c = await pump(tester);
    final label = tester.getSemantics(byKey('overview-bar-waiting')).label;
    final before = tester.getTopLeft(familyCard('ks-r21'));
    await tester.tap(byKey('overview-bar-waiting'));
    await settleMission(tester);
    expect(c.read(overviewDrawerProvider).open, isTrue);
    final drawer = tester.getRect(byKey('overview-waiting-drawer'));
    final bar = tester.getRect(byKey('overview-phone-bar'));
    expect(drawer.bottom, moreOrLessEquals(bar.top));
    expect(drawer.width, 390);
    expect(byKey('overview-queue-card:ks-r21'), findsOneWidget);
    final asks = find.byWidgetPredicate(
      (w) => switch (w.key) {
        ValueKey<String>(:final value) => value.startsWith(
          'overview-queue-card:',
        ),
        _ => false,
      },
    );
    expect(label, 'Waiting, ${asks.evaluate().length}');
    // Nothing behind it moved.
    expect(tester.getTopLeft(familyCard('ks-r21')), before);
    await tester.tap(byKey('overview-bar-waiting'));
    await settleMission(tester);
    expect(c.read(overviewDrawerProvider).open, isFalse);
    await unmountMission(tester);
  });

  testWidgets('Search opens a full-height sheet: what needs you, then what '
      'is new; typing lists the matches and a pick shows it on the board', (
    tester,
  ) async {
    final c = await pump(tester);
    await tester.tap(byKey('overview-bar-search'));
    await settleMission(tester);
    expect(c.read(overviewSearchSheetProvider), isTrue);
    final sheet = tester.getRect(byKey('overview-search-sheet'));
    final bar = tester.getRect(byKey('overview-phone-bar'));
    expect(sheet.bottom, moreOrLessEquals(bar.top));
    // It covers the board from the strip down.
    final strip = tester.getRect(byKey('overview-strip'));
    expect(sheet.top, lessThanOrEqualTo(strip.bottom + Insets.xxl * 2));
    expect(byKey('overview-search-hint:Needs you:ks-r21'), findsOneWidget);

    await tester.enterText(byKey('overview-search-sheet-field'), '1.34 prep');
    await settleMission(tester);
    expect(c.read(overviewSearchProvider).query, '1.34 prep');
    expect(byKey('overview-search-hint:Needs you:ks-r21'), findsNothing);
    final hit = find.byWidgetPredicate(
      (w) => switch (w.key) {
        ValueKey<String>(:final value) =>
          value.startsWith('overview-search-hint:') &&
              value.endsWith(':ks-release'),
        _ => false,
      },
    );
    expect(hit, findsOneWidget);
    await tester.tap(hit);
    await settleMission(tester);
    expect(c.read(overviewSearchSheetProvider), isFalse);
    expect(byKey('overview-search-sheet'), findsNothing);
    expect(c.read(overviewFocusProvider).selected, 'ks-release');
    // A phone's board shows no query, so the pick leaves none behind.
    expect(c.read(overviewSearchProvider).active, isFalse);
    await unmountMission(tester);
  });

  testWidgets('the sheet\'s New and Pinned are the strip\'s highlights, and '
      'narrow its list', (tester) async {
    final c = await pump(tester);
    await tester.tap(byKey('overview-bar-search'));
    await settleMission(tester);
    await tester.tap(byKey('overview-search-sheet-pinned'));
    await settleMission(tester);
    expect(c.read(overviewHighlightProvider), OverviewHighlight.pinned);
    // Nothing is pinned: nothing to list.
    expect(byKey('overview-search-sheet-empty'), findsOneWidget);
    await tester.tap(byKey('overview-search-sheet-new'));
    await settleMission(tester);
    expect(c.read(overviewHighlightProvider), OverviewHighlight.fresh);
    expect(byKey('overview-search-sheet-empty'), findsNothing);
    await tester.tap(byKey('overview-search-sheet-close'));
    await settleMission(tester);
    expect(byKey('overview-search-sheet'), findsNothing);
    // The highlight stays on the board.
    expect(c.read(overviewHighlightProvider), OverviewHighlight.fresh);
    await unmountMission(tester);
  });

  testWidgets('Next new goes to the next new session, as U does', (
    tester,
  ) async {
    final c = await pump(tester);
    final seen = c.read(overviewSeenProvider);
    String? selected() => c.read(overviewFocusProvider).selected;
    await tester.tap(byKey('overview-bar-next-new'));
    await settleMission(tester);
    final first = selected();
    expect(first, isNotNull);
    expect(seen.containsKey(first), isFalse, reason: 'never opened: new');
    await tester.tap(byKey('overview-bar-next-new'));
    await settleMission(tester);
    expect(selected(), isNotNull);
    expect(selected(), isNot(first));
    await unmountMission(tester);
  });

  testWidgets('Lanes brings the lane chips into reach: the lit one takes '
      'the focus', (tester) async {
    await pump(tester);
    await tester.tap(byKey('overview-bar-lanes'));
    await settleMission(tester);
    final focused = FocusManager.instance.primaryFocus;
    expect(focused?.debugLabel, startsWith('overview-lane-chip:'));
    final chip = tester.getRect(
      find.byKey(
        ValueKey(
          'overview-lane-chip:'
          '${focused!.debugLabel!.substring('overview-lane-chip:'.length)}',
        ),
      ),
    );
    expect(chip.left, greaterThanOrEqualTo(0));
    expect(chip.right, lessThanOrEqualTo(390));
    await unmountMission(tester);
  });

  testWidgets('no overflow in the bar or the sheet at 360 px and text '
      'scale 1.6', (tester) async {
    for (final scale in const [1.0, 1.6]) {
      await pump(tester, size: const Size(360, 800), scale: scale);
      expect(tester.takeException(), isNull, reason: '$scale');
      await tester.tap(byKey('overview-bar-search'));
      await settleMission(tester);
      expect(tester.takeException(), isNull, reason: 'sheet $scale');
      await tester.tap(byKey('overview-bar-waiting'));
      await settleMission(tester);
      expect(tester.takeException(), isNull, reason: 'drawer $scale');
      await unmountMission(tester);
    }
  });
}
