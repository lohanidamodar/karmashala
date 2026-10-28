import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/explorer/application/agent_states.dart';
import 'package:karmashala/src/features/overview/application/overview_drawer.dart';
import 'package:karmashala/src/features/overview/application/overview_family_order.dart';
import 'package:karmashala/src/features/overview/application/overview_links.dart';
import 'package:karmashala/src/features/overview/application/overview_prefs.dart';
import 'package:karmashala/src/features/overview/application/overview_search.dart';
import 'package:karmashala_ui/tokens.dart';

import 'mission_fixture.dart';

/// **The stable dashboard** (round 118): a change of state never moves or
/// resizes a family; the owner's hand order outlives a restart; and nothing
/// overflows from 360 px to wide, at text scale 1.6.
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ks-overview-stable');
  });
  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } on FileSystemException {
      // The prefs file may still be held open on Windows; the OS sweeps temp.
    }
  });

  Finder byKey(String key) => find.byKey(ValueKey(key));

  /// Every family card on the board, by root id, at its top left; its size
  /// too, so a card that grows in place is caught as well.
  Map<String, Rect> families(WidgetTester tester) => {
    for (final element
        in find
            .byWidgetPredicate(
              (w) => switch (w.key) {
                ValueKey<String>(:final value) => value.startsWith(
                  'overview-family:',
                ),
                _ => false,
              },
            )
            .evaluate())
      (element.widget.key! as ValueKey<String>).value: tester.getRect(
        find.byKey(element.widget.key!),
      ),
  };

  Future<ProviderContainer> pump(WidgetTester tester, Size size) => pumpMission(
    tester,
    fixture: MissionFixture.full(),
    prefsDir: dir,
    size: size,
    phone: size.width < WidthClass.mediumMin,
  );

  group('no movement', () {
    for (final (name, size) in const [
      ('1440', Size(1440, 900)),
      ('390', Size(390, 844)),
    ]) {
      testWidgets('$name px: no family moves or resizes as sessions go '
          'working → ready → needs you → working, nor when the last ask is '
          'answered', (tester) async {
        final c = await pump(tester, size);
        // One family folded; another with five sub-sessions open.
        c.read(overviewFoldedParentsProvider.notifier).toggle('beej-scaffold');
        await settleMission(tester);
        expect(c.read(overviewFoldedParentsProvider), {'beej-scaffold'});
        expect(
          byKey('overview-tree-node:ks-r32-sub4'),
          findsOneWidget,
          reason: 'the five-strong family draws its rows',
        );
        final before = families(tester);
        expect(before.length, greaterThanOrEqualTo(10));
        expect(before.keys, contains('overview-family:ks-r32'));
        expect(before.keys, contains('overview-family:beej-scaffold'));

        final states = c.read(missionStatesProvider.notifier);
        Future<void> still(String step) async {
          await settleMission(tester);
          expect(tester.takeException(), isNull, reason: step);
          final now = families(tester);
          expect(now.keys.toSet(), before.keys.toSet(), reason: step);
          for (final MapEntry(:key, :value) in before.entries) {
            expect(now[key]!.topLeft, value.topLeft, reason: '$step: $key');
            expect(now[key]!.size, value.size, reason: '$step: $key');
          }
        }

        // A root, a sub-session of the open family, a folded family's root
        // and its sub-session, and a ready root that starts the round there.
        const working = [
          'ks-release',
          'ks-r32-sub0',
          'beej-scaffold',
          'beej-scaffold-sub0',
        ];
        for (final to in const [
          AgentState.ready,
          AgentState.needsYou,
          AgentState.working,
        ]) {
          for (final id in working) {
            states.flip(id, to);
          }
          await still('all to ${to.name}');
        }
        for (final to in const [
          AgentState.needsYou,
          AgentState.working,
          AgentState.ready,
        ]) {
          states.flip('ks-r30', to);
          await still('ks-r30 to ${to.name}');
        }
        // The last ask answered: the one session that needed you works on.
        for (final id in working) {
          states.flip(id, AgentState.working);
        }
        states.flip('ks-r21', AgentState.working);
        await still('the last ask answered');
        await unmountMission(tester);
      });
    }
  });

  group('order persists', () {
    test('a fresh container reads the hand order back, and step moves on '
        'from it', () async {
      const lane = 'lane-a';
      ProviderContainer open() => ProviderContainer(
        overrides: [
          overviewPrefsDirectoryProvider.overrideWithValue(() async => dir),
        ],
      );
      final file = File(
        '${dir.path}${Platform.pathSeparator}'
        'overview_family_order.json',
      );

      final first = open();
      first
          .read(overviewFamilyOrderProvider.notifier)
          .move(lane, const ['a', 'b', 'c'], 'c', 0);
      expect(first.read(overviewFamilyOrderProvider)[lane], ['c', 'a', 'b']);
      for (var i = 0; i < 100 && !file.existsSync(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
      first.dispose();
      expect(jsonDecode(file.readAsStringSync()), {
        lane: ['c', 'a', 'b'],
      });

      // The restart: nothing but the file carries it.
      final second = open();
      addTearDown(second.dispose);
      second.read(overviewFamilyOrderProvider);
      for (
        var i = 0;
        i < 100 && second.read(overviewFamilyOrderProvider).isEmpty;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(second.read(overviewFamilyOrderProvider)[lane], ['c', 'a', 'b']);
      second
          .read(overviewFamilyOrderProvider.notifier)
          .step(lane, const ['c', 'a', 'b'], 'a', -1);
      expect(second.read(overviewFamilyOrderProvider)[lane], ['a', 'c', 'b']);
    });

    testWidgets('a hand reorder redraws the lane in the new order, and a '
        'restarted board draws it the same', (tester) async {
      var c = await pump(tester, const Size(1440, 900));
      final forest = c.read(overviewForestProvider);
      final (lane, trees) = forest.lanes.firstWhere((l) => l.$2.length >= 3);
      final roots = [for (final tree in trees) tree.card.id];
      final firstAt = tester.getTopLeft(familyCard(roots.first));
      final last = roots.last;

      c
          .read(overviewFamilyOrderProvider.notifier)
          .move(lane.key, roots, last, 0);
      await settleMission(tester);
      List<String> drawn() => [
        for (final tree
            in c
                .read(overviewForestProvider)
                .lanes
                .firstWhere((l) => l.$1.key == lane.key)
                .$2)
          tree.card.id,
      ];
      expect(drawn(), [last, ...roots.take(roots.length - 1)]);
      expect(tester.getTopLeft(familyCard(last)), firstAt);

      // Move later, as the menu's "Move later" does: one step on.
      c
          .read(overviewFamilyOrderProvider.notifier)
          .step(lane.key, drawn(), last, 1);
      await settleMission(tester);
      expect(drawn(), [
        roots.first,
        last,
        ...roots.sublist(1, roots.length - 1),
      ]);
      expect(tester.getTopLeft(familyCard(roots.first)), firstAt);
      final secondAt = tester.getTopLeft(familyCard(last));

      final file = File(
        '${dir.path}${Platform.pathSeparator}'
        'overview_family_order.json',
      );
      await tester.runAsync(() async {
        for (var i = 0; i < 100; i++) {
          Object? kept;
          try {
            kept = (jsonDecode(file.readAsStringSync()) as Map)[lane.key];
          } on Object {
            // Not there yet, or caught mid-write.
          }
          if (kept case [
            final String a,
            final String b,
            ...,
          ] when a == roots.first && b == last) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await tester.pump();
        }
      });
      expect(file.existsSync(), isTrue, reason: 'the order is kept on disk');
      expect(
        (jsonDecode(file.readAsStringSync()) as Map)[lane.key],
        c.read(overviewFamilyOrderProvider)[lane.key],
      );
      await unmountMission(tester);

      // The restart: a fresh container, the same prefs folder.
      c = await pump(tester, const Size(1440, 900));
      await tester.runAsync(() async {
        for (
          var i = 0;
          i < 100 && c.read(overviewFamilyOrderProvider).isEmpty;
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await tester.pump();
        }
      });
      await settleMission(tester);
      expect(drawn(), [
        roots.first,
        last,
        ...roots.sublist(1, roots.length - 1),
      ]);
      expect(tester.getTopLeft(familyCard(last)), secondAt);
      await unmountMission(tester);
    });
  });

  group('no overflow', () {
    for (final (name, size, scale) in const [
      ('360', Size(360, 800), 1.0),
      ('360 at 1.6', Size(360, 800), 1.6),
      ('1440', Size(1440, 900), 1.0),
      ('1440 at 1.6', Size(1440, 900), 1.6),
    ]) {
      testWidgets('$name: the board, the search results and the drawer', (
        tester,
      ) async {
        final c = await pumpMission(
          tester,
          fixture: MissionFixture.full(),
          prefsDir: dir,
          size: size,
          phone: size.width < WidthClass.mediumMin,
          textScale: scale,
        );
        expect(tester.takeException(), isNull, reason: 'board');
        // Down the whole board, so every family is laid out on screen.
        final list = tester.state<ScrollableState>(hybridList).position;
        list.jumpTo(list.maxScrollExtent);
        await settleMission(tester);
        expect(tester.takeException(), isNull, reason: 'scrolled');

        // The search's results: the phone's sheet, or the strip's list.
        if (size.width < WidthClass.mediumMin) {
          c.read(overviewSearchSheetProvider.notifier).open();
          await settleMission(tester);
          expect(byKey('overview-search-sheet-list'), findsOneWidget);
          await tester.enterText(byKey('overview-search-sheet-field'), 'Round');
          await settleMission(tester);
          expect(byKey('overview-search-sheet-list'), findsOneWidget);
          expect(tester.takeException(), isNull, reason: 'search sheet');
          c.read(overviewSearchSheetProvider.notifier).close();
          c.read(overviewSearchProvider.notifier).clear();
        } else {
          await tester.tap(byKey('overview-search'));
          await settleMission(tester);
          expect(byKey('overview-search-list'), findsOneWidget);
          expect(tester.takeException(), isNull, reason: 'search list');
          FocusManager.instance.primaryFocus?.unfocus();
        }
        await settleMission(tester);

        c.read(overviewDrawerProvider.notifier).open();
        await settleMission(tester);
        expect(byKey('overview-queue-card:ks-r21'), findsOneWidget);
        expect(tester.takeException(), isNull, reason: 'drawer');
        c.read(overviewDrawerProvider.notifier).open(family: 'ks-r21');
        await settleMission(tester);
        expect(tester.takeException(), isNull, reason: 'drawer, one family');
        await unmountMission(tester);
      });
    }
  });
}
