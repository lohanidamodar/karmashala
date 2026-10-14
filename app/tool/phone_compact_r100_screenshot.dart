// Renders round 100's dashboard tree on a phone — a Pixel at 412×915,
// 360×800, and 360 px at text 1.6 — and on a desktop at 1440 px, each as the
// first screen and as a tall page holding every family.
// Under tool/ so `flutter test` never picks it up; run it from app/:
//
//   flutter test tool/phone_compact_r100_screenshot.dart \
//     --dart-define=SHOT_DIR=<folder> --dart-define=SHOT_TAG=after
//
// Images land in SHOT_DIR, build/phone-compact-r100-shots/ by default.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/features/overview/mission_fixture.dart';

const _outDir = String.fromEnvironment(
  'SHOT_DIR',
  defaultValue: 'build/phone-compact-r100-shots',
);
const _tag = String.fromEnvironment('SHOT_TAG', defaultValue: 'shot');

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
  setUpAll(_loadBundledFonts);

  Future<void> shoot(
    WidgetTester tester,
    String name, {
    required Size size,
    bool phone = true,
    double textScale = 1,
    bool toReady = false,
  }) async {
    final key = GlobalKey();
    await pumpMission(
      tester,
      fixture: MissionFixture.full(),
      prefsDir: Directory.systemTemp.createTempSync('ks-r100-shot'),
      size: size,
      phone: phone,
      textScale: textScale,
      boundary: key,
    );
    if (toReady) {
      final ready = find.byKey(const ValueKey('overview-ready'));
      await tester.scrollUntilVisible(ready, 300, scrollable: hybridList);
      await tester.ensureVisible(ready);
      await settleMission(tester);
    }
    await tester.runAsync(() async {
      final render =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await render.toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      Directory(_outDir).createSync(recursive: true);
      File(
        '$_outDir/$_tag-$name.png',
      ).writeAsBytesSync(bytes!.buffer.asUint8List());
    });
    expect(tester.takeException(), isNull);
    await unmountMission(tester);
  }

  testWidgets('412', (t) => shoot(t, '412', size: const Size(412, 915)));
  testWidgets(
    '412, ready',
    (t) => shoot(t, '412-ready', size: const Size(412, 915), toReady: true),
  );
  testWidgets(
    '412, tall',
    (t) => shoot(t, '412-tall', size: const Size(412, 3600)),
  );
  testWidgets('360', (t) => shoot(t, '360', size: const Size(360, 800)));
  testWidgets(
    '360, tall',
    (t) => shoot(t, '360-tall', size: const Size(360, 4000)),
  );
  testWidgets(
    '360, text 1.6, tall',
    (t) => shoot(
      t,
      '360-text160-tall',
      size: const Size(360, 6000),
      textScale: 1.6,
    ),
  );
  testWidgets(
    'desktop',
    (t) => shoot(t, 'desktop', size: const Size(1440, 1600), phone: false),
  );
}
