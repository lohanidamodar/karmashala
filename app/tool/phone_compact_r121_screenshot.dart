// Renders round 121's phone dashboard whole — the phone shell, its top bar,
// the board's header and strip, and the navigation bar — at 390×844 and at
// 360×800 with text at 1.6, and prints where the first family card starts.
// Under tool/ so `flutter test` never picks it up; run it from app/:
//
//   flutter test tool/phone_compact_r121_screenshot.dart \
//     --dart-define=SHOT_DIR=<folder> --dart-define=SHOT_TAG=after
//
// Images land in SHOT_DIR, build/phone-compact-r121-shots/ by default.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/phone_shell.dart';
import 'package:karmashala/src/features/overview/application/overview_seen.dart';

import '../test/features/overview/mission_fixture.dart';

const _outDir = String.fromEnvironment(
  'SHOT_DIR',
  defaultValue: 'build/phone-compact-r121-shots',
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

/// False measures in the test font, as the widget tests do.
const _fonts = bool.fromEnvironment('SHOT_FONTS', defaultValue: true);

void main() {
  if (_fonts) setUpAll(_loadBundledFonts);

  Future<void> shoot(
    WidgetTester tester,
    String name, {
    required Size size,
    double textScale = 1,
  }) async {
    final key = GlobalKey();
    final c = await pumpMission(
      tester,
      fixture: MissionFixture.full(),
      prefsDir: Directory.systemTemp.createTempSync('ks-r121-shot'),
      size: size,
      phone: true,
      textScale: textScale,
      boundary: key,
      home: const PhoneShell(),
    );
    await tester.runAsync(() async {
      for (var i = 0; i < 100 && !c.read(overviewSeenReadProvider); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await settleMission(tester);
    final first = firstFamilyTop(tester);
    final nav = tester.getTopLeft(find.byType(NavigationBar)).dy;
    // ignore: avoid_print
    print('r121 $_tag $name: first family top $first, nav bar top $nav');
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

  testWidgets('390', (t) => shoot(t, '390', size: const Size(390, 844)));
  testWidgets(
    '360, text 1.6',
    (t) => shoot(t, '360-x16', size: const Size(360, 800), textScale: 1.6),
  );
}
