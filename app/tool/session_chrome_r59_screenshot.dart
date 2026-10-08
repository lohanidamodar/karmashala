// Renders round 59's session chrome — the peek's header, view switch and
// status strip — at 360, 412 and 1440 px, at text 1.0 and 1.6. Under tool/
// so `flutter test` never picks it up; run it explicitly from app/:
//
//   flutter test tool/session_chrome_r59_screenshot.dart --dart-define=SHOTS=after
//
// Images land in build/session-chrome-r59/<SHOTS>/.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/sessions/presentation/chat_transcript.dart';

import '../test/features/overview/mission_fixture.dart';

const _label = String.fromEnvironment('SHOTS', defaultValue: 'after');
const _outDir = 'build/session-chrome-r59/$_label';

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

List<ChatMessage> _conversation(DateTime now) => [
  ChatMessage(
    role: 'user',
    text: 'Slim the session header; the status bar should say it all.',
    at: now.subtract(const Duration(minutes: 30)),
  ),
  ChatMessage(
    role: 'agent',
    text:
        'The header is one row now, and the status strip folds what does '
        'not fit into +N.',
    at: now.subtract(const Duration(minutes: 4)),
  ),
];

void main() {
  setUpAll(_loadBundledFonts);

  Future<void> shoot(
    WidgetTester tester,
    String name, {
    required Size size,
    required bool phone,
    required double textScale,
  }) async {
    final key = GlobalKey();
    final now = MissionFixture.now;
    await pumpMission(
      tester,
      fixture: _fixture(now),
      prefsDir: Directory.systemTemp.createTempSync('ks-r59-shot'),
      size: size,
      phone: phone,
      textScale: textScale,
      boundary: key,
    );
    final open = phone
        ? find.byKey(const ValueKey('overview-phone-row:ks-r32'))
        : find.text('Round 32 · Overview redesign').first;
    await tester.scrollUntilVisible(open, 200, scrollable: hybridList);
    await tester.tap(open);
    await settleMission(tester);
    await tester.pump(const Duration(seconds: 1));
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

  for (final (width, height, phone) in const [
    (360.0, 800.0, true),
    (412.0, 915.0, true),
    (1440.0, 900.0, false),
  ]) {
    for (final scale in const [1.0, 1.6]) {
      final tag = '${width.round()}-text${(scale * 100).round()}';
      testWidgets(
        tag,
        (t) => shoot(
          t,
          'peek-$tag',
          size: Size(width, height),
          phone: phone,
          textScale: scale,
        ),
      );
    }
  }
}

/// [MissionFixture.full] with a terminal pane, so every view is there.
MissionFixture _fixture(DateTime now) {
  final full = MissionFixture.full();
  return MissionFixture(
    peekChat: (entry, seenUntil) => ChatTranscriptView(
      messages: _conversation(now),
      seenUntil: now.subtract(const Duration(minutes: 20)),
    ),
    models: full.models,
    stats: full.stats,
    fileStats: full.fileStats,
    answers: full.answers,
    glances: full.glances,
    files: full.files,
    activity: full.activity,
    panes: const {'ks-r32': 'pane-r32'},
  );
}
