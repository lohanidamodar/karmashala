// Renders round 119's family cards — a ready session alone, a working
// family, one that needs you, an ended one — cropped from the dashboard at
// 1440 px and at phone widths, and, given SHOT_REPLY, with the footer's
// message box open on the ready card.
// Under tool/ so `flutter test` never picks it up; run it from app/:
//
//   flutter test tool/card_footer_r119_screenshot.dart \
//     --dart-define=SHOT_DIR=<folder> --dart-define=SHOT_TAG=after \
//     --dart-define=SHOT_REPLY=true
//
// Images land in SHOT_DIR, build/card-footer-r119-shots/ by default.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/overview/application/overview_providers.dart';

import '../test/features/overview/mission_fixture.dart';

const _outDir = String.fromEnvironment(
  'SHOT_DIR',
  defaultValue: 'build/card-footer-r119-shots',
);
const _tag = String.fromEnvironment('SHOT_TAG', defaultValue: 'shot');
const _reply = bool.fromEnvironment('SHOT_REPLY');
const _hover = bool.fromEnvironment('SHOT_HOVER');

const _cards = ['ks-r30', 'ks-r32', 'ks-r21', 'ks-r29', 'web-blog'];

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
    double textScale = 1,
    bool reply = false,
    Future<void> Function(WidgetTester, ProviderContainer)? act,
    List<String>? only,
  }) async {
    final key = GlobalKey();
    final container = await pumpMission(
      tester,
      fixture: MissionFixture.full(),
      prefsDir: Directory.systemTemp.createTempSync('ks-r119-shot'),
      size: size,
      phone: size.width < 600,
      textScale: textScale,
      boundary: key,
    );
    if (reply) {
      final button = find.byKey(const ValueKey('overview-family-reply:ks-r30'));
      unawaited(
        Scrollable.ensureVisible(tester.element(button), alignment: 0.6),
      );
      await settleMission(tester);
      await tester.tap(button);
      await settleMission(tester);
      await tester.enterText(
        find.byKey(const ValueKey('overview-composer:ks-r30')),
        'Run the webhook tests again',
      );
      await settleMission(tester);
    }
    if (act != null) {
      await act(tester, container);
      await settleMission(tester);
    }
    await tester.runAsync(() async {
      final render =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final origin = render.localToGlobal(Offset.zero);
      final image = await render.toImage(pixelRatio: 1);
      Directory(_outDir).createSync(recursive: true);
      for (final id in only ?? (reply ? const ['ks-r30'] : _cards)) {
        final card = find.byKey(ValueKey('overview-family:$id'));
        if (card.evaluate().isEmpty) continue;
        final rect = tester.getRect(card).shift(-origin).inflate(8);
        final clip = rect.intersect(Offset.zero & size);
        if (clip.isEmpty) continue;
        final recorder = ui.PictureRecorder();
        Canvas(
          recorder,
        ).drawImageRect(image, clip, Offset.zero & clip.size, Paint());
        final cropped = await recorder.endRecording().toImage(
          clip.width.round(),
          clip.height.round(),
        );
        final bytes = await cropped.toByteData(format: ui.ImageByteFormat.png);
        cropped.dispose();
        File(
          '$_outDir/$_tag-$name-$id.png',
        ).writeAsBytesSync(bytes!.buffer.asUint8List());
      }
      image.dispose();
    });
    expect(tester.takeException(), isNull);
    await unmountMission(tester);
  }

  testWidgets('1440', (t) => shoot(t, '1440', size: const Size(1440, 4000)));
  testWidgets('390', (t) => shoot(t, '390', size: const Size(390, 6000)));
  testWidgets(
    '360, text 1.6',
    (t) => shoot(t, '360-x16', size: const Size(360, 9000), textScale: 1.6),
  );
  if (_hover) {
    Future<void> point(WidgetTester tester, String key) async {
      final at = find.byKey(ValueKey(key));
      await tester.ensureVisible(at);
      await settleMission(tester);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: tester.getCenter(at));
      addTearDown(mouse.removePointer);
      await tester.pump();
    }

    for (final (name, act)
        in <(String, Future<void> Function(WidgetTester, ProviderContainer))>[
          ('hover-parent', (t, _) => point(t, 'overview-family-head:ks-r32')),
          ('hover-sub', (t, _) => point(t, 'overview-tree-pill:ks-r32-sub2')),
          ('hover-more', (t, _) => point(t, 'overview-card-menu:ks-r32')),
          (
            'keys-parent',
            (t, c) async =>
                c.read(overviewFocusProvider.notifier).select('ks-r32'),
          ),
          (
            'keys-sub',
            (t, c) async =>
                c.read(overviewFocusProvider.notifier).select('ks-r32-sub2'),
          ),
        ]) {
      testWidgets(
        name,
        (t) => shoot(
          t,
          '1440-$name',
          size: const Size(1440, 1400),
          act: act,
          only: const ['ks-r32'],
        ),
      );
    }
  }
  if (_reply) {
    for (final (name, size, scale) in const [
      ('1440', Size(1440, 1400), 1.0),
      ('390', Size(390, 844), 1.0),
      ('360-x16', Size(360, 800), 1.6),
    ]) {
      testWidgets(
        '$name, reply open',
        (t) =>
            shoot(t, '$name-reply', size: size, textScale: scale, reply: true),
      );
    }
  }
}
