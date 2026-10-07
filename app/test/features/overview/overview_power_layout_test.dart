import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'mission_fixture.dart';
import 'power_fixture.dart';

/// **Round 48 at every size**: pins, a batch, usage and a limit warning —
/// and two peeks at 1600 px — fit at 360, 1100 and 1600 px with text at
/// 1.6×, dark and light.
void main() {
  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ks-overview-power');
  });
  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } on FileSystemException {
      // Windows may still hold the prefs file; the OS sweeps temp.
    }
  });

  for (final brightness in Brightness.values) {
    for (final (width, height, phone) in const [
      (360.0, 800.0, true),
      (1100.0, 800.0, false),
      (1600.0, 1000.0, false),
    ]) {
      testWidgets('${width.round()} px, text 1.6, ${brightness.name}', (
        tester,
      ) async {
        await pumpPowerBoard(
          tester,
          prefsDir: dir,
          size: Size(width, height),
          phone: phone,
          brightness: brightness,
          textScale: 1.6,
        );
        expect(find.byKey(const ValueKey('overview-batch-bar')), findsOne);
        expect(find.byKey(const ValueKey('overview-pinned')), findsOne);
        if (width >= 1600) {
          expect(
            find.byKey(const ValueKey('overview-side-by-side-peeks')),
            findsOne,
          );
        }
        // Scroll the whole board through, so every card is laid out.
        await tester.drag(hybridList, const Offset(0, -4000));
        await settleMission(tester);
        expect(tester.takeException(), isNull);
        await unmountMission(tester);
      });
    }
  }
}
