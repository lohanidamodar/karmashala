import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/phone_shell.dart';
import 'package:karmashala/src/app/shell/quick_open/quick_open.dart';
import 'package:karmashala/src/features/overview/application/overview_drawer.dart';
import 'package:karmashala/src/features/overview/application/overview_prefs.dart';
import 'package:karmashala/src/features/overview/application/overview_providers.dart';
import 'package:karmashala/src/features/overview/application/overview_search.dart';
import 'package:karmashala/src/features/overview/application/overview_seen.dart';
import 'package:karmashala_ui/tokens.dart';

import 'mission_fixture.dart';

/// **The phone dashboard's one strip** (round 121, replacing round 118's
/// bottom bar): "N waiting", "N new", Today's counts and the lane chips in
/// one compact row; search on the top bar's magnifier; Activity in the
/// filter popover; only the app's own navigation bar at the bottom.
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ks-phone-strip');
  });
  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } on FileSystemException {
      // The prefs file may still be held open on Windows; the OS sweeps temp.
    }
  });

  Finder byKey(String key) => find.byKey(ValueKey(key));

  Finder laneChips() => find.byWidgetPredicate(
    (w) => switch (w.key) {
      ValueKey<String>(:final value) => value.startsWith('overview-lane-chip:'),
      _ => false,
    },
  );

  /// The dashboard as the phone's home, in its shell, or — [shell] false —
  /// its tab alone.
  Future<ProviderContainer> pump(
    WidgetTester tester, {
    Size size = const Size(390, 844),
    double scale = 1,
    bool shell = true,
  }) async {
    final phone = size.width < WidthClass.mediumMin;
    final c = await pumpMission(
      tester,
      fixture: MissionFixture.full(),
      prefsDir: dir,
      size: size,
      phone: phone,
      textScale: scale,
      home: shell && phone ? const PhoneShell() : null,
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

  testWidgets('a phone has no dashboard bar: only the app\'s navigation bar '
      'is under the board', (tester) async {
    await pump(tester);
    expect(byKey('overview-phone-bar'), findsNothing);
    for (final key in const [
      'overview-bar-search',
      'overview-bar-waiting',
      'overview-bar-next-new',
      'overview-bar-lanes',
    ]) {
      expect(byKey(key), findsNothing, reason: key);
    }
    expect(find.byType(NavigationBar), findsOneWidget);
    // The board runs down to the navigation bar.
    final board = tester.getRect(byKey('overview-hybrid'));
    final nav = tester.getRect(find.byType(NavigationBar));
    expect(board.bottom, moreOrLessEquals(nav.top));
    await unmountMission(tester);
  });

  testWidgets('the counts and the lanes are one row of compact chips', (
    tester,
  ) async {
    await pump(tester);
    final strip = tester.getRect(byKey('overview-strip'));
    // No row of lane chips of its own, and no desktop controls.
    expect(byKey('overview-lane-chips'), findsNothing);
    for (final key in const [
      'overview-search',
      'overview-strip-new',
      'overview-strip-pinned',
      'overview-waiting-toggle',
      'overview-more-toggle',
      'overview-today:needsYou',
    ]) {
      expect(byKey(key), findsNothing, reason: key);
    }
    for (final key in const [
      'overview-strip-waiting',
      'overview-strip-next-new',
      'overview-today',
    ]) {
      final rect = tester.getRect(byKey(key));
      expect(rect.top, greaterThanOrEqualTo(strip.top), reason: key);
      expect(rect.bottom, lessThanOrEqualTo(strip.bottom), reason: key);
    }
    expect(laneChips(), findsWidgets);
    for (final chip in laneChips().evaluate()) {
      final rect = tester.getRect(find.byWidget(chip.widget));
      expect(rect.top, greaterThanOrEqualTo(strip.top));
      expect(rect.bottom, lessThanOrEqualTo(strip.bottom));
      // The compact face the app's controls draw under a thumb.
      expect(rect.height, Touch.compactControl);
    }
    expect(
      tester.getSize(byKey('overview-strip-waiting')).height,
      Touch.compactControl,
    );
    expect(strip.height, Touch.compactControl);
    await unmountMission(tester);
  });

  testWidgets('at 390×844 the first family starts at least 80 dp higher '
      'than round 118\'s 320', (tester) async {
    await pump(tester);
    // Measured with tool/phone_compact_r121_screenshot.dart and
    // SHOT_FONTS=false, the test font: 320 on a710e7ca6, 236 after.
    expect(firstFamilyTop(tester), lessThanOrEqualTo(320 - 80));
    await unmountMission(tester);
  });

  testWidgets('wide, the strip keeps its controls and the lane chips their '
      'own row', (tester) async {
    await pump(tester, size: const Size(1440, 900));
    expect(byKey('overview-strip-waiting'), findsNothing);
    expect(byKey('overview-lane-chips'), findsOneWidget);
    for (final key in const [
      'overview-search',
      'overview-strip-new',
      'overview-strip-pinned',
      'overview-waiting-toggle',
      'overview-more-toggle',
    ]) {
      expect(byKey(key), findsOneWidget, reason: key);
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

  testWidgets('"N waiting" counts the asks and opens the drawer as a bottom '
      'sheet over the board, down to the navigation bar', (tester) async {
    final c = await pump(tester);
    final asks = find.byWidgetPredicate(
      (w) => switch (w.key) {
        ValueKey<String>(:final value) => value.startsWith(
          'overview-queue-card:',
        ),
        _ => false,
      },
    );
    final before = tester.getTopLeft(familyCard('ks-r21'));
    await tester.tap(byKey('overview-strip-waiting'));
    await settleMission(tester);
    expect(c.read(overviewDrawerProvider).open, isTrue);
    final count = asks.evaluate().length;
    expect(count, greaterThan(0));
    expect(
      tester.getSemantics(byKey('overview-strip-waiting')).label,
      startsWith('$count waiting on you'),
    );
    final drawer = tester.getRect(byKey('overview-waiting-drawer'));
    final nav = tester.getRect(find.byType(NavigationBar));
    expect(drawer.bottom, moreOrLessEquals(nav.top));
    expect(drawer.width, 390);
    expect(byKey('overview-queue-card:ks-r21'), findsOneWidget);
    // Nothing behind it moved.
    expect(tester.getTopLeft(familyCard('ks-r21')), before);
    await tester.tap(byKey('overview-strip-waiting'));
    await settleMission(tester);
    expect(c.read(overviewDrawerProvider).open, isFalse);
    await unmountMission(tester);
  });

  testWidgets('"N new" goes to the next new session, as U does', (
    tester,
  ) async {
    final c = await pump(tester);
    final seen = c.read(overviewSeenProvider);
    String? selected() => c.read(overviewFocusProvider).selected;
    await tester.tap(byKey('overview-strip-next-new'));
    await settleMission(tester);
    final first = selected();
    expect(first, isNotNull);
    expect(seen.containsKey(first), isFalse, reason: 'never opened: new');
    await tester.tap(byKey('overview-strip-next-new'));
    await settleMission(tester);
    expect(selected(), isNotNull);
    expect(selected(), isNot(first));
    await unmountMission(tester);
  });

  testWidgets('a lane chip in the strip goes to its lane and lights', (
    tester,
  ) async {
    await pump(tester);
    final keys = [
      for (final chip in laneChips().evaluate())
        (chip.widget.key! as ValueKey<String>).value,
    ];
    expect(keys.length, greaterThan(1));
    bool lit(String key) =>
        tester.widget<Material>(byKey(key)).color != Colors.transparent;
    // The first lane is on screen, and lit.
    expect(lit(keys.first), isTrue);
    final second = byKey(keys[1]);
    await tester.ensureVisible(second);
    await settleMission(tester);
    await tester.tap(second);
    await settleMission(tester);
    await settleMission(tester);
    // Its lane's header came up to the top of the board, and its chip lit.
    expect(lit(keys[1]), isTrue);
    expect(lit(keys.first), isFalse);
    await unmountMission(tester);
  });

  group('search, on the top bar\'s magnifier', () {
    testWidgets('on the Dashboard\'s board it opens the full-height sheet: '
        'what needs you, then what is new; a pick shows it on the board', (
      tester,
    ) async {
      final c = await pump(tester);
      await tester.tap(byKey('phone-top-search'));
      await settleMission(tester);
      expect(c.read(overviewSearchSheetProvider), isTrue);
      expect(find.byType(QuickOpen), findsNothing);
      final sheet = tester.getRect(byKey('overview-search-sheet'));
      final nav = tester.getRect(find.byType(NavigationBar));
      expect(sheet.bottom, moreOrLessEquals(nav.top));
      // It covers the board from the strip down.
      final strip = tester.getRect(byKey('overview-strip'));
      expect(sheet.top, lessThanOrEqualTo(strip.bottom + Insets.xxl * 2));
      expect(byKey('overview-search-hint:Needs you:ks-r21'), findsOneWidget);

      await tester.enterText(byKey('overview-search-sheet-field'), '1.34 prep');
      await settleMission(tester);
      expect(c.read(overviewSearchProvider).query, '1.34 prep');
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

    testWidgets('the sheet goes on to quick open with what was typed', (
      tester,
    ) async {
      final c = await pump(tester);
      await tester.tap(byKey('phone-top-search'));
      await settleMission(tester);
      await tester.enterText(byKey('overview-search-sheet-field'), 'webhook');
      await settleMission(tester);
      await tester.tap(byKey('overview-search-sheet-everything'));
      await settleMission(tester);
      expect(c.read(overviewSearchSheetProvider), isFalse);
      expect(find.byType(QuickOpen), findsOneWidget);
      expect(
        tester.widget<QuickOpen>(find.byType(QuickOpen)).initialQuery,
        'webhook',
      );
      await unmountMission(tester);
    });

    testWidgets('on the Timeline, or another tab, it is quick open', (
      tester,
    ) async {
      final c = await pump(tester);
      c.read(overviewPrefsProvider.notifier).setView(OverviewView.timeline);
      await settleMission(tester);
      await tester.tap(byKey('phone-top-search'));
      await settleMission(tester);
      expect(c.read(overviewSearchSheetProvider), isFalse);
      expect(find.byType(QuickOpen), findsOneWidget);
      await unmountMission(tester);
    });

    testWidgets('the sheet\'s New and Pinned are the strip\'s highlights, '
        'and narrow its list', (tester) async {
      final c = await pump(tester);
      await tester.tap(byKey('phone-top-search'));
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

    testWidgets('a narrow window, with no phone top bar, searches from the '
        'board\'s header', (tester) async {
      // The tab in a desktop's workbench, not the phone's root tab.
      final c = await pumpMission(
        tester,
        fixture: MissionFixture.full(),
        prefsDir: dir,
        size: const Size(500, 900),
      );
      expect(byKey('overview-strip-waiting'), findsOneWidget);
      await tester.tap(byKey('overview-header-search'));
      await settleMission(tester);
      expect(c.read(overviewSearchSheetProvider), isTrue);
      expect(byKey('overview-search-sheet'), findsOneWidget);
      await unmountMission(tester);
    });
  });

  testWidgets('Activity is a switch in the filter popover on a phone', (
    tester,
  ) async {
    final c = await pump(tester);
    expect(byKey('overview-heartbeat'), findsNothing);
    await toggleActivity(tester);
    expect(c.read(overviewMoreProvider), isTrue);
    expect(byKey('overview-heartbeat'), findsOneWidget);
    await toggleActivity(tester);
    expect(c.read(overviewMoreProvider), isFalse);
    await unmountMission(tester);
  });

  for (final (size, scale) in const [
    (Size(360, 800), 1.0),
    (Size(360, 800), 1.6),
    (Size(390, 844), 1.0),
    (Size(390, 844), 1.6),
    (Size(1440, 900), 1.0),
  ]) {
    testWidgets('no overflow at ${size.width.round()} px and text scale '
        '$scale: board, search, drawer and Activity', (tester) async {
      final phone = size.width < WidthClass.mediumMin;
      final c = await pump(tester, size: size, scale: scale);
      expect(tester.takeException(), isNull, reason: 'board');
      if (phone) {
        await tester.tap(byKey('phone-top-search'));
        await settleMission(tester);
        expect(tester.takeException(), isNull, reason: 'sheet');
        c.read(overviewSearchSheetProvider.notifier).close();
        await settleMission(tester);
      }
      await openWaiting(tester);
      expect(tester.takeException(), isNull, reason: 'drawer');
      c.read(overviewDrawerProvider.notifier).close();
      await settleMission(tester);
      await toggleActivity(tester);
      expect(tester.takeException(), isNull, reason: 'activity');
      await unmountMission(tester);
    });
  }
}
