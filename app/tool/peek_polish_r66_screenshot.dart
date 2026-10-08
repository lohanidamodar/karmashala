// Renders round 66's peek: its one-line header at 650, 1100 and 360 px, and
// the status strip's +N list on a desktop and at 390 px, at text 1.0 and 1.6.
// Under tool/ so `flutter test` never picks it up; run it explicitly from
// app/:
//
//   flutter test tool/peek_polish_r66_screenshot.dart --dart-define=SHOTS=after
//
// Images land in build/peek-polish-r66/<SHOTS>/.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/phone_shell.dart' show PhoneTabsScope;
import 'package:karmashala/src/app/widgets/row_menu_sheet.dart';
import 'package:karmashala/src/features/explorer/presentation/session_rows.dart';
import 'package:karmashala/src/features/overview/presentation/overview_tab_view.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/menus.dart' show RowMenuSheetScope;
import 'package:karmashala/src/app/widgets/status_strip.dart';
import 'package:karmashala/src/features/overview/application/overview_providers.dart';
import 'package:karmashala/src/features/overview/application/overview_tiles.dart';
import 'package:karmashala/src/features/overview/presentation/overview_peek.dart';
import 'package:karmashala/src/features/sessions/presentation/chat_transcript.dart';

import '../test/features/overview/mission_fixture.dart';

const _label = String.fromEnvironment('SHOTS', defaultValue: 'after');
const _outDir = 'build/peek-polish-r66/$_label';

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
    text: 'Stop, Open, the views: can they all fit on one line?',
    at: now.subtract(const Duration(minutes: 30)),
  ),
  ChatMessage(
    role: 'agent',
    text: 'One row now, and the +N sheet is a list.',
    at: now.subtract(const Duration(minutes: 4)),
  ),
];

/// The peek alone, as the board docks it, for one session of the fixture.
class _Peek extends ConsumerWidget {
  const _Peek({required this.compact, this.width});

  final bool compact;

  /// The peek's own width, docked at the window's end; the window's when null.
  final double? width;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final card = overviewCardOf(ref.watch(overviewBoardProvider), 'ks-r32');
    if (card == null) return const SizedBox.shrink();
    return Scaffold(
      body: Align(
        alignment: Alignment.centerRight,
        child: SizedBox(
          width: width ?? double.infinity,
          child: OverviewPeek(
            card: card,
            compact: compact,
            onClose: () {},
            onPrevious: () {},
            onNext: () {},
          ),
        ),
      ),
    );
  }
}

void main() {
  setUpAll(_loadBundledFonts);

  Future<void> shoot(
    WidgetTester tester,
    String name, {
    required Size size,
    required bool phone,
    required double textScale,
    bool fold = false,
    double? peekWidth,
    Widget? home,
    Future<void> Function(WidgetTester tester)? act,
  }) async {
    final key = GlobalKey();
    final now = MissionFixture.now;
    await pumpMission(
      tester,
      fixture: _fixture(now),
      prefsDir: Directory.systemTemp.createTempSync('ks-r66-shot'),
      size: size,
      phone: phone,
      textScale: textScale,
      boundary: key,
      // The app's own sheet for a row's menu under a thumb.
      home: RowMenuSheetScope(
        present: showRowMenuSheet,
        child: home ?? _Peek(compact: phone, width: peekWidth),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    await settleMission(tester);
    if (fold) {
      final plus = find.byKey(StatusStrip.foldKey);
      expect(plus, findsOneWidget, reason: 'nothing folded at $size');
      await tester.tap(plus);
      await settleMission(tester);
    }
    if (act != null) {
      await act(tester);
      await settleMission(tester);
    }
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

  for (final (width, phone) in const [
    (650.0, false),
    (1100.0, false),
    (360.0, true),
  ]) {
    for (final scale in const [1.0, 1.6]) {
      final tag = '${width.round()}-text${(scale * 100).round()}';
      testWidgets(
        'header $tag',
        (t) => shoot(
          t,
          'header-$tag',
          size: Size(width, 520),
          phone: phone,
          textScale: scale,
        ),
      );
    }
  }
  for (final (width, peek, phone) in const [
    (1100.0, 420.0, false),
    (390.0, null, true),
  ]) {
    for (final scale in const [1.0, 1.6]) {
      final tag = '${width.round()}-text${(scale * 100).round()}';
      testWidgets(
        'sheet $tag',
        (t) => shoot(
          t,
          'sheet-$tag',
          size: Size(width, 844),
          phone: phone,
          textScale: scale,
          fold: true,
          peekWidth: peek,
        ),
      );
    }
  }
  Future<void> openMenu(WidgetTester tester, Finder button) async {
    await tester.ensureVisible(button);
    await settleMission(tester);
    await tester.tap(button);
  }

  for (final (width, phone) in const [(1440.0, false), (390.0, true)]) {
    final tag = '${width.round()}';
    final size = Size(width, phone ? 844 : 900);
    testWidgets(
      'menu on a card $tag',
      (t) => shoot(
        t,
        'menu-card-$tag',
        size: size,
        phone: phone,
        textScale: 1,
        home: phone
            ? const Scaffold(
                body: PhoneTabsScope(
                  child: PaneTitleOverride(child: OverviewTabView()),
                ),
              )
            : const OverviewTabView(),
        act: (t) async {
          final menu = find.byKey(const ValueKey('overview-card-menu:ks-r32'));
          await t.scrollUntilVisible(menu, 200, scrollable: hybridList);
          await openMenu(t, menu);
        },
      ),
    );
    testWidgets(
      'menu on a sidebar row $tag',
      (t) => shoot(
        t,
        'menu-sidebar-$tag',
        size: size,
        phone: phone,
        textScale: 1,
        home: const _SidebarRow(),
        act: (t) async {
          final row = find.byType(NativeSessionRow);
          if (phone) {
            // The row's ⋮, as a thumb opens it.
            await t.tap(
              find.descendant(
                of: row,
                matching: find.byIcon(AppIcons.dotsThreeVertical),
              ),
            );
          } else {
            await t.tap(row, buttons: kSecondaryButton);
          }
        },
      ),
    );
    testWidgets(
      'menu on the peek $tag',
      (t) => shoot(
        t,
        'menu-peek-$tag',
        size: size,
        phone: phone,
        textScale: 1,
        peekWidth: phone ? null : 650,
        act: (t) =>
            openMenu(t, find.byKey(const ValueKey('overview-peek-more'))),
      ),
    );
  }
}

/// The fixture's session as the sidebar draws it.
class _SidebarRow extends ConsumerWidget {
  const _SidebarRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = overviewCardOf(
      ref.watch(overviewBoardProvider),
      'ks-r32',
    )?.entry.native;
    return Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 320,
          child: session == null
              ? const SizedBox.shrink()
              : NativeSessionRow(session: session, depth: 0),
        ),
      ),
    );
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
