import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/explorer/application/agent_states.dart';
import 'package:karmashala/src/features/sessions/application/host_lifecycle/host_lifecycle_providers.dart';

import 'mission_fixture.dart';

/// **A family's Stop under a thumb** (round 120): always drawn, as tall as
/// the ⋯, from a 360 px phone at 1.6x text without overflow; End is the
/// footer's power button as well as in the ⋯; an ended family has Archive in
/// Stop's place and no End.
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ks-end-button');
  });
  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } on FileSystemException {
      // The prefs file may still be held open on Windows; the OS sweeps temp.
    }
  });

  for (final (width, scale) in [(360.0, 1.0), (360.0, 1.6), (412.0, 1.6)]) {
    testWidgets(
      '${width}px at ${scale}x: Stop on every live family, End in its ⋯',
      (tester) async {
        final fixture = MissionFixture.full();
        await pumpMission(
          tester,
          fixture: fixture,
          prefsDir: dir,
          size: Size(width, 800),
          phone: true,
          textScale: scale,
          // Every session in the fixture runs at the server.
          overrides: [
            sessionRunningOnHostProvider.overrideWithValue((_) => true),
          ],
        );
        final ends = find.byWidgetPredicate(
          (w) =>
              w.key is ValueKey<String> &&
              (w.key! as ValueKey<String>).value.startsWith(
                'overview-interrupt:',
              ),
        );
        expect(ends, findsWidgets);
        for (final slot in tester.widgetList<AnimatedOpacity>(
          find.byWidgetPredicate(
            (w) =>
                w is AnimatedOpacity &&
                w.key is ValueKey<String> &&
                (w.key! as ValueKey<String>).value.startsWith(
                  'overview-end-slot:',
                ),
          ),
        )) {
          expect(slot.opacity, 1, reason: '${slot.key}');
        }
        // As tall a target as the ⋯ beside it.
        final first = (tester.widget(ends.first).key! as ValueKey<String>).value
            .substring('overview-interrupt:'.length);
        expect(
          tester.getSize(ends.first).height,
          tester
              .getSize(find.byKey(ValueKey('overview-card-menu:$first')))
              .height,
        );
        // No ended session offers one.
        for (final s in fixture.sessions) {
          if (s.state == AgentState.ended) {
            expect(
              find.byKey(ValueKey('overview-interrupt:${s.id}')),
              findsNothing,
            );
          }
        }
        expect(tester.takeException(), isNull);
        await unmountMission(tester);
      },
    );
  }

  group('the power button', () {
    Finder end(String id) => find.byKey(ValueKey('overview-family-end:$id'));

    Future<void> board(WidgetTester tester, {required bool runs}) async {
      await pumpMission(
        tester,
        fixture: MissionFixture.full(),
        prefsDir: dir,
        size: const Size(1440, 900),
        overrides: [
          sessionRunningOnHostProvider.overrideWithValue((_) => runs),
        ],
      );
    }

    Future<void> reveal(WidgetTester tester, Finder finder) async {
      await tester.scrollUntilVisible(finder, 200, scrollable: hybridList);
      await settleMission(tester);
    }

    testWidgets('on a running session it asks, and No ends nothing', (
      tester,
    ) async {
      await board(tester, runs: true);
      await reveal(tester, end('ks-r30'));
      await tester.tap(end('ks-r30'));
      await settleMission(tester);
      expect(find.text('End session'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await settleMission(tester);
      expect(find.byType(SnackBar), findsNothing);
      expect(end('ks-r30'), findsOneWidget);
      await unmountMission(tester);
    });

    testWidgets('with nothing running it stays, disabled, and says why', (
      tester,
    ) async {
      await board(tester, runs: false);
      await reveal(tester, end('ks-r30'));
      expect(tester.widget<OutlinedButton>(end('ks-r30')).onPressed, isNull);
      expect(find.byTooltip('Nothing is running this session'), findsWidgets);
      await unmountMission(tester);
    });

    testWidgets('an ended session has none, and keeps its place', (
      tester,
    ) async {
      await board(tester, runs: false);
      final archive = find.byWidgetPredicate(
        (w) =>
            w is OutlinedButton &&
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith(
              'overview-done-archive:',
            ),
      );
      await reveal(tester, archive.first);
      final key = tester.widget(archive.first).key! as ValueKey<String>;
      expect(end(key.value.split(':').last), findsNothing);
      await unmountMission(tester);
    });
  });
}
