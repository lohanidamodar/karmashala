import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/overview/application/overview_prefs.dart';
import 'package:karmashala/src/features/overview/application/overview_providers.dart';

import 'mission_fixture.dart';

/// **Pinned sessions**: up to three, kept per device, in a strip above the
/// groups; two of them side by side where the window is 1600 px or wider.
void main() {
  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ks-overview-pins');
  });
  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } on FileSystemException {
      // The prefs file may still be held open on Windows; the OS sweeps temp.
    }
  });

  group('kept per device', () {
    ProviderContainer open() {
      final c = ProviderContainer(
        overrides: [
          overviewPrefsDirectoryProvider.overrideWithValue(() async => dir),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    test('at most three, in the order pinned, across a reload', () async {
      final first = open();
      final prefs = first.read(overviewPrefsProvider.notifier);
      expect(prefs.togglePin('a'), isTrue);
      expect(prefs.togglePin('b'), isTrue);
      expect(prefs.togglePin('c'), isTrue);
      expect(prefs.togglePin('d'), isFalse);
      expect(prefs.togglePin('b'), isTrue);
      expect(first.read(overviewPrefsProvider).pinned, ['a', 'c']);

      final file = File('${dir.path}/overview_device.json');
      for (var i = 0; i < 200 && !file.existsSync(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final second = open();
      second.read(overviewPrefsProvider);
      for (var i = 0; i < 200; i++) {
        if (second.read(overviewPrefsProvider).pinned.isNotEmpty) break;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(second.read(overviewPrefsProvider).pinned, ['a', 'c']);
    });

    test('a file holding more than three keeps the first three', () {
      final prefs = OverviewPrefs.fromJson({
        'pinned': ['a', 'b', 'a', 'c', 'd'],
      });
      expect(prefs.pinned, ['a', 'b', 'c']);
      expect(const OverviewPrefs().toJson().containsKey('pinned'), isFalse);
    });
  });

  group('on the board', () {
    Future<ProviderContainer> pump(WidgetTester tester, Size size) async {
      final container = await pumpMission(
        tester,
        fixture: MissionFixture.full(),
        prefsDir: dir,
        size: size,
      );
      final prefs = container.read(overviewPrefsProvider.notifier);
      prefs.togglePin('ks-release');
      prefs.togglePin('ks-r32');
      await settleMission(tester);
      return container;
    }

    final strip = find.byKey(const ValueKey('overview-pinned'));
    final sideBySide = find.byKey(const ValueKey('overview-side-by-side'));

    testWidgets('the strip holds the pinned cards above the groups', (
      tester,
    ) async {
      await pump(tester, const Size(1440, 900));
      expect(strip, findsOneWidget);
      expect(find.text('PINNED · 2'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('overview-pinned-card:ks-release')),
        findsOneWidget,
      );
      final stripTop = tester.getTopLeft(strip).dy;
      final queueTop = tester
          .getTopLeft(find.byKey(const ValueKey('overview-queue')))
          .dy;
      expect(stripTop, lessThan(queueTop));
      await unmountMission(tester);
    });

    testWidgets('below 1600 px there is one peek and no side by side', (
      tester,
    ) async {
      final container = await pump(tester, const Size(1440, 900));
      expect(sideBySide, findsNothing);
      container
          .read(overviewFocusProvider.notifier)
          .peekSideBySide('ks-release', 'ks-r32');
      await settleMission(tester);
      expect(find.byKey(const ValueKey('overview-peek')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('overview-peek-beside:ks-r32')),
        findsNothing,
      );
      await unmountMission(tester);
    });

    testWidgets('at 1600 px and wider two live peeks dock together', (
      tester,
    ) async {
      await pump(tester, const Size(1700, 1000));
      await tester.tap(sideBySide);
      await settleMission(tester);
      expect(find.byKey(const ValueKey('overview-peek')), findsNWidgets(2));
      expect(
        find.byKey(const ValueKey('overview-peek:ks-release')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('overview-peek-beside:ks-r32')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('overview-peek-chat:ks-r32')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await unmountMission(tester);
    });

    testWidgets('Pin and Unpin from the peek header and the card menu', (
      tester,
    ) async {
      final container = await pump(tester, const Size(1440, 900));
      container.read(overviewFocusProvider.notifier).peek('ks-r21');
      await settleMission(tester);
      await tester.tap(find.byKey(const ValueKey('overview-peek-pin')));
      await settleMission(tester);
      expect(container.read(overviewPrefsProvider).pinned, [
        'ks-release',
        'ks-r32',
        'ks-r21',
      ]);

      final menu = find.byKey(const ValueKey('overview-card-menu:ks-r32'));
      await tester.tap(menu.first);
      await settleMission(tester);
      await tester.tap(find.text('Unpin').last);
      await settleMission(tester);
      expect(container.read(overviewPrefsProvider).pinned, [
        'ks-release',
        'ks-r21',
      ]);
      await unmountMission(tester);
    });
  });
}
