import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/explorer/application/agent_states.dart';
import 'package:karmashala/src/features/sessions/application/host_lifecycle/host_lifecycle_providers.dart';

import 'mission_fixture.dart';

/// **A card's quick End under a thumb**: always drawn on a live session, at
/// the ⋯'s size, from a 360 px phone at 1.6x text without overflow; never on
/// an ended one.
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
    testWidgets('${width}px at ${scale}x: on every live row, at full ink', (
      tester,
    ) async {
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
            (w.key! as ValueKey<String>).value.startsWith('overview-end:'),
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
      // The same target as the ⋯ beside it.
      final first = (tester.widget(ends.first).key! as ValueKey<String>).value
          .substring('overview-end:'.length);
      expect(
        tester.getSize(ends.first),
        tester.getSize(find.byKey(ValueKey('overview-card-menu:$first'))),
      );
      // No ended session offers one.
      for (final s in fixture.sessions) {
        if (s.state == AgentState.ended) {
          expect(find.byKey(ValueKey('overview-end:${s.id}')), findsNothing);
        }
      }
      expect(tester.takeException(), isNull);
      await unmountMission(tester);
    });
  }
}
