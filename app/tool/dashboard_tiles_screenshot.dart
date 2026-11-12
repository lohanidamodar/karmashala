// Renders the dashboard's project tiles — a finished, seen family as one
// line, the rest as cards — at 1440 px, grouped by project and by context,
// and at phone widths.
// Under tool/ so `flutter test` never picks it up; run it from app/:
//
//   flutter test tool/dashboard_tiles_screenshot.dart \
//     --dart-define=SHOT_DIR=<folder> --dart-define=SHOT_TAG=after
//
// Images land in SHOT_DIR, build/dashboard-tiles-shots/ by default.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/overview/application/overview_board.dart';
import 'package:karmashala/src/features/overview/application/overview_prefs.dart';

import '../test/features/overview/mission_fixture.dart';

const _outDir = String.fromEnvironment(
  'SHOT_DIR',
  defaultValue: 'build/dashboard-tiles-shots',
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

MissionFixture _filed() => MissionFixture(
  contexts: const [
    OverviewLaneKey('c-pb', 'PopupBits'),
    OverviewLaneKey('c-infra', 'Infrastructure'),
  ],
  contextOfProject: const {
    'p-ks': 'c-pb',
    'p-beej': 'c-pb',
    'p-web': 'c-pb',
    'p-relay': 'c-infra',
  },
  answers: MissionFixture.realisticAnswers(),
  glances: MissionFixture.realisticGlances(),
  files: MissionFixture.realisticFiles(),
  stats: MissionFixture.realisticStats(),
);

void main() {
  setUpAll(_loadBundledFonts);

  Future<void> shoot(
    WidgetTester tester,
    String name, {
    required Size size,
    double textScale = 1,
    Future<void> Function(WidgetTester, ProviderContainer)? act,
  }) async {
    final key = GlobalKey();
    final container = await pumpMission(
      tester,
      fixture: _filed(),
      prefsDir: Directory.systemTemp.createTempSync('ks-tiles-shot'),
      size: size,
      phone: size.width < 600,
      textScale: textScale,
      boundary: key,
      lines: true,
    );
    if (act != null) {
      await act(tester, container);
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

  Future<void> byContext(WidgetTester _, ProviderContainer c) async => c
      .read(overviewPrefsProvider.notifier)
      .setGroupBy(OverviewGroupBy.context);

  testWidgets('1440', (t) => shoot(t, '1440', size: const Size(1440, 1300)));
  testWidgets(
    '1440, by context',
    (t) =>
        shoot(t, '1440-context', size: const Size(1440, 1500), act: byContext),
  );
  testWidgets('1024', (t) => shoot(t, '1024', size: const Size(1024, 1300)));
  testWidgets('390', (t) => shoot(t, '390', size: const Size(390, 2600)));
  testWidgets(
    '360, text 1.6',
    (t) => shoot(t, '360-x16', size: const Size(360, 4000), textScale: 1.6),
  );
}
