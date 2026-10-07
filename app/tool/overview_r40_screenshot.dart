// Renders round 40's Agent dashboard over the mission fixture into PNGs: the
// board with its peek at 1440 and 1100, and the phone list at 390 and 360,
// dark and light. Under tool/ so `flutter test` never picks it up; run it
// explicitly from app/:
//
//   flutter test tool/overview_r40_screenshot.dart
//
// Images land in build/overview-r40-shots/.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/overview/application/overview_providers.dart';
import 'package:karmashala/src/features/sessions/presentation/chat_transcript.dart';

import '../test/features/overview/mission_fixture.dart';

const _outDir = 'build/overview-r40-shots';

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

/// A conversation for the peek to draw in place of a server's.
List<ChatMessage> _conversation(DateTime now) => [
  ChatMessage(
    role: 'user',
    text: 'Build the hybrid Overview: queue on the left, cards on the right.',
    at: now.subtract(const Duration(minutes: 40)),
  ),
  ChatMessage(
    role: 'agent',
    text: 'The queue and the cards are in. Writing the layout tests next.',
    at: now.subtract(const Duration(minutes: 30)),
  ),
  ChatMessage(
    role: 'agent',
    text: 'Two layout tests fail at 360 px: the counters wrap. Fixing it.',
    at: now.subtract(const Duration(minutes: 8)),
  ),
  ChatMessage(
    role: 'agent',
    text: 'All 41 overview tests pass. Moving on to the peek.',
    at: now.subtract(const Duration(minutes: 2)),
  ),
];

void main() {
  setUpAll(_loadBundledFonts);

  Future<void> shoot(
    WidgetTester tester,
    String name, {
    required Size size,
    bool phone = false,
    Brightness brightness = Brightness.dark,
    double textScale = 1,
    String? peek,
  }) async {
    final key = GlobalKey();
    final now = MissionFixture.now;
    final container = await pumpMission(
      tester,
      fixture: MissionFixture.full(
        peekChat: (entry, seenUntil) => ChatTranscriptView(
          messages: _conversation(now),
          seenUntil: now.subtract(const Duration(minutes: 20)),
        ),
      ),
      prefsDir: Directory.systemTemp.createTempSync('ks-overview-r40-shot'),
      size: size,
      phone: phone,
      brightness: brightness,
      textScale: textScale,
      boundary: key,
    );
    if (peek != null) {
      container.read(overviewFocusProvider.notifier).peek(peek);
      await settleMission(tester);
    }
    await tester.runAsync(() async {
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

  for (final brightness in Brightness.values) {
    final tone = brightness.name;
    testWidgets(
      '1440 $tone',
      (t) => shoot(
        t,
        'board-1440-$tone',
        size: const Size(1440, 900),
        brightness: brightness,
      ),
    );
    testWidgets(
      '1440 $tone, peek docked',
      (t) => shoot(
        t,
        'board-1440-peek-$tone',
        size: const Size(1440, 900),
        brightness: brightness,
        peek: 'ks-r32',
      ),
    );
    testWidgets(
      '1100 $tone, peek over the board',
      (t) => shoot(
        t,
        'board-1100-peek-$tone',
        size: const Size(1100, 800),
        brightness: brightness,
        peek: 'ks-r32',
      ),
    );
    testWidgets(
      '390 $tone',
      (t) => shoot(
        t,
        'phone-390-$tone',
        size: const Size(390, 844),
        phone: true,
        brightness: brightness,
      ),
    );
    testWidgets(
      '360 $tone',
      (t) => shoot(
        t,
        'phone-360-$tone',
        size: const Size(360, 800),
        phone: true,
        brightness: brightness,
      ),
    );
  }
  testWidgets(
    '390 dark, text 1.6',
    (t) => shoot(
      t,
      'phone-390-text160',
      size: const Size(390, 844),
      phone: true,
      textScale: 1.6,
    ),
  );
}
