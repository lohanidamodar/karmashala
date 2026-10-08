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
import 'package:karmashala/src/app/shell/phone_shell.dart';
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
    Widget? home,
    Future<void> Function(WidgetTester tester, dynamic container)? before,
  }) async {
    final key = GlobalKey();
    final container = await pumpMission(
      tester,
      fixture: fixture ?? MissionFixture.full(),
      prefsDir: Directory.systemTemp.createTempSync('ks-overview-shot'),
      size: size,
      phone: phone,
      brightness: brightness,
      textScale: textScale,
      boundary: key,
      home: home,
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
        await tester.tap(find.byKey(const ValueKey('overview-card:ks-r32')));
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
    'desktop, by context',
    (t) => shoot(
      t,
      'desktop-1440-contexts',
      fixture: MissionFixture(
        answers: MissionFixture.realisticAnswers(),
        glances: MissionFixture.realisticGlances(),
        files: MissionFixture.realisticFiles(),
        activity: MissionFixture.realisticActivity(),
        contexts: const [
          OverviewLaneKey('c-apps', 'Apps'),
          OverviewLaneKey('c-web', 'Web'),
        ],
        contextOfProject: const {
          'p-ks': 'c-apps',
          'p-beej': 'c-apps',
          'p-web': 'c-web',
        },
      ),
      before: (tester, container) async {
        container
            .read(overviewPrefsProvider.notifier)
            .setGroupBy(OverviewGroupBy.context);
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
    'phone 390, peek sheet',
    (t) => shoot(
      t,
      'phone-390-peek',
      size: const Size(390, 844),
      phone: true,
      before: (tester, _) async {
        await tester.tap(find.text('Round 21 · ACP sessions').first);
      },
    ),
  );
  testWidgets(
    'desktop light, peek docked',
    (t) => shoot(
      t,
      'desktop-1440-light-peek',
      brightness: Brightness.light,
      before: (tester, _) async {
        await tester.tap(find.byKey(const ValueKey('overview-card:ks-r32')));
      },
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
  // The whole phone shell: the Dashboard as its first tab and home.
  for (final width in [360.0, 412.0]) {
    testWidgets(
      'phone shell $width',
      (t) => shoot(
        t,
        'phone-shell-${width.round()}',
        size: Size(width, 800),
        phone: true,
        home: const PhoneShell(),
      ),
    );
  }
  // The view-and-filters panel with some filters set, at both ends of the
  // width range and at 1× and 1.6× text.
  for (final (name, size, phone) in [
    ('360', const Size(360, 640), true),
    ('1440', const Size(1440, 900), false),
  ]) {
    for (final scale in [1.0, 1.6]) {
      testWidgets(
        'panel $name at $scale',
        (t) => shoot(
          t,
          'panel-$name-text${(scale * 100).round()}',
          size: size,
          phone: phone,
          textScale: scale,
          before: (tester, container) async {
            container.read(overviewPrefsProvider.notifier)
              ..setMachines({'windows', 'wsl:arch'})
              ..setProjects({'p-ks', 'p-beej'});
            await tester.pump();
            await tester.tap(
              find.byKey(const ValueKey('overview-filter-button')),
            );
          },
        ),
      );
    }
  }
  for (final (name, size, phone) in [
    ('360', const Size(360, 640), true),
    ('1440', const Size(1440, 900), false),
  ]) {
    for (final scale in [1.0, 1.6]) {
      testWidgets(
        'keys $name at $scale',
        (t) => shoot(
          t,
          'keys-$name-text${(scale * 100).round()}',
          size: size,
          phone: phone,
          textScale: scale,
          before: (tester, _) async {
            await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
            await tester.sendKeyEvent(LogicalKeyboardKey.slash, character: '?');
            await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
          },
        ),
      );
    }
  }
  // The phone's Dashboard tab: its one-row header and triage line.
  for (final width in [360.0, 390.0, 412.0]) {
    for (final scale in [1.0, 1.6]) {
      testWidgets(
        'dashboard phone $width at $scale',
        (t) => shoot(
          t,
          'dash-phone-${width.round()}-text${(scale * 100).round()}',
          size: Size(width, 800),
          phone: true,
          textScale: scale,
        ),
      );
    }
  }
  testWidgets(
    'cards, details hidden',
    (t) => shoot(
      t,
      'cards-1440-details-hidden',
      fixture: MissionFixture(
        answers: MissionFixture.realisticAnswers(),
        glances: MissionFixture.realisticGlances(),
        files: MissionFixture.realisticFiles(),
        activity: MissionFixture.realisticActivity(),
        contexts: const [
          OverviewLaneKey('c-apps', 'Apps'),
          OverviewLaneKey('c-web', 'Web'),
        ],
        contextOfProject: const {
          'p-ks': 'c-apps',
          'p-beej': 'c-apps',
          'p-web': 'c-web',
        },
      ),
      before: (tester, container) async {
        container.read(overviewPrefsProvider.notifier)
          ..setDetailShown(OverviewCardDetail.context, false)
          ..setDetailShown(OverviewCardDetail.machine, false);
      },
    ),
  );
  testWidgets(
    'cards, every detail',
    (t) => shoot(
      t,
      'cards-1440-details-all',
      fixture: MissionFixture(
        answers: MissionFixture.realisticAnswers(),
        glances: MissionFixture.realisticGlances(),
        files: MissionFixture.realisticFiles(),
        activity: MissionFixture.realisticActivity(),
        contexts: const [
          OverviewLaneKey('c-apps', 'Apps'),
          OverviewLaneKey('c-web', 'Web'),
        ],
        contextOfProject: const {
          'p-ks': 'c-apps',
          'p-beej': 'c-apps',
          'p-web': 'c-web',
        },
      ),
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
