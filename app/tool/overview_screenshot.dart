// Renders mission control over a realistic fixture into PNGs, so the layout
// can be looked at. Under tool/ so `flutter test` never picks it up; run it
// explicitly from app/:
//
//   flutter test tool/overview_screenshot.dart
//
// Images land in build/overview-shots/.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/explorer/application/agent_states.dart';
import 'package:karmashala/src/features/overview/application/overview_board.dart';
import 'package:karmashala/src/features/overview/application/overview_prefs.dart';

import '../test/features/overview/mission_fixture.dart';

const _outDir = 'build/overview-shots';

/// Every font the app bundles, by the family names its manifest gives them —
/// without this flutter_test draws each glyph as a box.
Future<void> _loadBundledFonts() async {
  final manifest =
      jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
  for (final family in manifest.cast<Map<String, Object?>>()) {
    final loader = FontLoader(family['family']! as String);
    for (final font
        in (family['fonts']! as List).cast<Map<String, Object?>>()) {
      loader.addFont(rootBundle.load(font['asset']! as String));
    }
    await loader.load();
  }
}

void main() {
  // Each shot keeps its prefs in a folder of its own, so one shot's filter
  // never leaks into the next.
  setUpAll(_loadBundledFonts);

  Future<void> shoot(
    WidgetTester tester,
    String name, {
    Size size = const Size(1440, 900),
    bool phone = false,
    Brightness brightness = Brightness.dark,
    double textScale = 1,
    MissionFixture? fixture,
    Future<void> Function(WidgetTester tester, dynamic container)? before,
  }) async {
    final key = GlobalKey();
    final container = await pumpMission(
      tester,
      fixture: fixture ?? MissionFixture(),
      prefsDir: Directory.systemTemp.createTempSync('ks-overview-shot'),
      size: size,
      phone: phone,
      brightness: brightness,
      textScale: textScale,
      boundary: key,
    );
    if (before != null) {
      await before(tester, container);
      await settleMission(tester);
    }
    await tester.runAsync(() async {
      // Let the agents' logo images decode before the frame is read.
      for (final element in find.byType(Image).evaluate()) {
        final image = element.widget as Image;
        await precacheImage(image.image, element);
      }
    });
    await settleMission(tester);
    await tester.runAsync(() async {
      final render =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await render.toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      Directory(_outDir).createSync(recursive: true);
      File('$_outDir/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    });
    expect(tester.takeException(), isNull);
    await unmountMission(tester);
  }

  testWidgets('desktop dark', (t) => shoot(t, 'desktop-1440-dark'));
  testWidgets(
    'desktop light',
    (t) => shoot(t, 'desktop-1440-light', brightness: Brightness.light),
  );
  testWidgets(
    'desktop 1024',
    (t) => shoot(t, 'desktop-1024-dark', size: const Size(1024, 768)),
  );
  testWidgets(
    'desktop, peek docked',
    (t) => shoot(
      t,
      'desktop-1440-peek',
      before: (tester, _) async {
        await tester.tap(find.byKey(const ValueKey('overview-mark:ks-r21')));
      },
    ),
  );
  testWidgets(
    'desktop, working only',
    (t) => shoot(
      t,
      'desktop-1440-working-only',
      before: (tester, container) async {
        container.read(overviewPrefsProvider.notifier).setColumns({
          BoardColumn.working,
        });
      },
    ),
  );
  testWidgets(
    'desktop, by machine',
    (t) => shoot(
      t,
      'desktop-1440-machines',
      before: (tester, container) async {
        container
            .read(overviewPrefsProvider.notifier)
            .setGroupBy(OverviewGroupBy.machine);
      },
    ),
  );
  testWidgets(
    'desktop, filters',
    (t) => shoot(
      t,
      'desktop-1440-filters',
      before: (tester, container) async {
        container.read(overviewPrefsProvider.notifier).setMachines({
          'windows',
          'wsl:arch',
        });
        await tester.tap(find.byKey(const ValueKey('overview-filter-button')));
      },
    ),
  );
  testWidgets(
    'phone 390',
    (t) => shoot(t, 'phone-390-dark', size: const Size(390, 844), phone: true),
  );
  testWidgets(
    'phone 390 light',
    (t) => shoot(
      t,
      'phone-390-light',
      size: const Size(390, 844),
      phone: true,
      brightness: Brightness.light,
    ),
  );
  testWidgets(
    'phone 360',
    (t) => shoot(t, 'phone-360-dark', size: const Size(360, 640), phone: true),
  );
  testWidgets(
    'phone 390, text 1.6',
    (t) => shoot(
      t,
      'phone-390-text160',
      size: const Size(390, 844),
      phone: true,
      textScale: 1.6,
    ),
  );
  testWidgets(
    'phone 390, filters sheet',
    (t) => shoot(
      t,
      'phone-390-filters',
      size: const Size(390, 844),
      phone: true,
      before: (tester, _) async {
        await tester.tap(find.byKey(const ValueKey('overview-filter-button')));
      },
    ),
  );
  testWidgets(
    'empty',
    (t) => shoot(
      t,
      'desktop-1440-calm',
      fixture: MissionFixture(
        sessions: [
          for (final s in MissionFixture.realisticSessions())
            if (s.state == AgentState.ended) s,
        ],
      ),
    ),
  );
  testWidgets(
    'phone empty',
    (t) => shoot(
      t,
      'phone-390-calm',
      size: const Size(390, 844),
      phone: true,
      fixture: MissionFixture(
        sessions: [
          for (final s in MissionFixture.realisticSessions())
            if (s.state == AgentState.ended) s,
        ],
      ),
    ),
  );
}
