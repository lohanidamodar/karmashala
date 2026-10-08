import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/widgets/truncated_text.dart';
import 'package:karmashala/src/app/widgets/view_switch.dart';
import 'package:karmashala/src/features/explorer/application/workspace_session_entry.dart';
import 'package:karmashala/src/features/overview/application/overview_board.dart';
import 'package:karmashala/src/features/overview/application/overview_providers.dart';
import 'package:karmashala/src/features/overview/application/overview_tiles.dart';
import 'package:karmashala/src/features/overview/presentation/overview_peek.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/pane_lifecycle.dart';
import 'package:karmashala_ui/tokens.dart';

import 'mission_fixture.dart';

/// **The peek's one row** (round 66, owner, 2026-10-08: "stop, open tab,
/// chat, files can all fit in a single line?"): the agent, the title, the
/// views, Stop, Open, ↑ ↓, Pin, ⋯ and ✕ on one row at every width; what has
/// no room folds into ⋯ — Pin, then ↑ ↓, then Open, then Stop — and the
/// title names itself whole only once it is cut.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('ks-r66-header'));
  tearDown(() => dir.deleteSync(recursive: true));

  const id = 'ks-r32';
  const longTitle =
      'karmashala new features - after open, with a title long enough to cut';

  /// The peek alone, [width] wide, for the fixture's session — live, so it
  /// has Stop.
  Future<void> pump(
    WidgetTester tester, {
    required double width,
    bool phone = false,
    double textScale = 1,
    String? title,
  }) async {
    await pumpMission(
      tester,
      fixture: MissionFixture.full(),
      prefsDir: dir,
      size: Size(width, 700),
      phone: phone,
      textScale: textScale,
      overrides: [
        paneOfSessionProvider.overrideWith(
          (ref, session) => session == id ? 'pane-r32' : null,
        ),
        terminalPaneLivenessProvider.overrideWith(
          (ref, pane) => PaneLiveness.live,
        ),
      ],
      home: Scaffold(
        body: Consumer(
          builder: (context, ref, _) {
            final card = overviewCardOf(ref.watch(overviewBoardProvider), id);
            if (card == null) return const SizedBox.shrink();
            final entry = card.entry;
            final shown = title == null
                ? card
                : OverviewCard(
                    entry: WorkspaceSessionEntry(
                      id: entry.id,
                      title: title,
                      createdAt: entry.createdAt,
                      projectName: entry.projectName,
                      directory: entry.directory,
                      lastActiveAt: entry.lastActiveAt,
                      native: entry.native,
                      imported: entry.imported,
                    ),
                    state: card.state,
                    children: card.children,
                  );
            return OverviewPeek(
              card: shown,
              compact: phone,
              onClose: () {},
              onPrevious: () {},
              onNext: () {},
            );
          },
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    await settleMission(tester);
  }

  final header = find.byWidgetPredicate(
    (w) => w.runtimeType.toString() == '_PeekHeader',
  );
  Finder inHeader(Finder f) => find.descendant(of: header, matching: f);
  final title = find.byKey(const ValueKey('overview-peek-title'));

  /// [key] drawn in the row, not folded into ⋯.
  bool shown(String key) =>
      inHeader(find.byKey(ValueKey(key))).hitTestable().evaluate().isNotEmpty;

  /// Every control's top and bottom inside the title's line: one row.
  void expectOneRow(WidgetTester tester) {
    expect(tester.takeException(), isNull);
    final line = tester.getRect(title);
    for (final key in const [
      'overview-peek-tabs',
      'overview-peek-close',
      'overview-peek-stop',
      'overview-peek-open',
      'overview-peek-previous',
      'overview-peek-more',
    ]) {
      final f = inHeader(find.byKey(ValueKey(key))).hitTestable();
      if (f.evaluate().isEmpty) continue;
      final rect = tester.getRect(f);
      expect(rect.center.dy, closeTo(line.center.dy, 2), reason: key);
    }
    final row = tester.getRect(header);
    expect(row.height, lessThanOrEqualTo(Touch.target * 2), reason: 'plan');
  }

  for (final (width, phone) in const [
    (650.0, false),
    (1100.0, false),
    (360.0, true),
  ]) {
    for (final scale in const [1.0, 1.6]) {
      testWidgets('${width.round()} px, text ×$scale: one row, no overflow', (
        tester,
      ) async {
        await pump(tester, width: width, phone: phone, textScale: scale);
        expectOneRow(tester);
        // The views and ✕ (or back) never fold.
        expect(shown('overview-peek-tabs'), isTrue);
        expect(shown('overview-peek-close'), isTrue);
        final views = tester.widget<ViewSwitch<OverviewPeekTab>>(
          find.byKey(const ValueKey('overview-peek-tabs')),
        );
        expect(views.labelled, isFalse);
        await unmountMission(tester);
      });
    }
  }

  testWidgets('wide, everything is in the row; Open says Open', (tester) async {
    await pump(tester, width: 1100);
    for (final key in const [
      'overview-peek-stop',
      'overview-peek-open',
      'overview-peek-previous',
      'overview-peek-next',
      'overview-peek-control:pin',
    ]) {
      expect(shown(key), isTrue, reason: key);
    }
    expect(inHeader(find.text('Open')), findsOneWidget);
    expect(inHeader(find.text('Open tab')), findsNothing);
    expect(inHeader(find.text('Stop')), findsOneWidget);
    expect(find.byTooltip('Open in a tab'), findsOneWidget);
    await unmountMission(tester);
  });

  testWidgets('narrow, Open is a glyph that keeps its tooltip', (tester) async {
    await pump(tester, width: 520);
    expect(shown('overview-peek-open'), isTrue);
    expect(inHeader(find.text('Open')), findsNothing);
    expect(find.byTooltip('Open in a tab'), findsOneWidget);
    await unmountMission(tester);
  });

  testWidgets('the row folds Pin, then ↑ ↓, then Open, then Stop, into ⋯', (
    tester,
  ) async {
    const order = [
      'overview-peek-control:pin',
      'overview-peek-control:move',
      'overview-peek-control:open',
      'overview-peek-control:stop',
    ];
    final seen = <List<bool>>[];
    for (final width in const [1100.0, 700.0, 520.0, 440.0, 400.0, 360.0]) {
      await pump(tester, width: width, title: longTitle);
      expect(tester.takeException(), isNull, reason: '$width');
      seen.add([for (final key in order) !shown(key)]);
      await unmountMission(tester);
    }
    // At each width the folded ones are a prefix of the order: nothing folds
    // before what comes ahead of it.
    for (final folded in seen) {
      final n = folded.where((f) => f).length;
      expect(folded, [for (var i = 0; i < order.length; i++) i < n]);
    }
    // And it gets there: all in at 1100, all out by 360.
    expect(seen.first.where((f) => f), isEmpty);
    expect(seen.last.where((f) => f), hasLength(order.length));
  });

  testWidgets('what folds is in ⋯, and runs from there', (tester) async {
    await pump(tester, width: 360, title: longTitle);
    await tester.tap(find.byKey(const ValueKey('overview-peek-more')));
    await settleMission(tester);
    // The peek's own: what folded that the session menu does not hold.
    for (final key in const ['pin', 'previous', 'next']) {
      expect(
        find.byKey(ValueKey('overview-peek-menu:$key')),
        findsOneWidget,
        reason: key,
      );
    }
    // Open folds into the session menu's own Open — Stop into its End,
    // offered while the server's launcher runs the session.
    expect(find.byKey(const ValueKey('session-menu:open')), findsOneWidget);
    expect(find.text('Open in a tab'), findsOneWidget);
    await unmountMission(tester);
  });

  group('the title names itself only once it is cut', () {
    Tooltip? tooltipOf(WidgetTester tester) {
      final tips = find.descendant(of: title, matching: find.byType(Tooltip));
      if (tips.evaluate().isEmpty) return null;
      return tester.widget<Tooltip>(tips.first);
    }

    testWidgets('a title that fits: no tooltip', (tester) async {
      await pump(tester, width: 1100, title: 'Short');
      expect(tooltipOf(tester)?.message ?? '', isEmpty);
      await unmountMission(tester);
    });

    testWidgets('a cut title: hover shows it whole', (tester) async {
      await pump(tester, width: 650, title: longTitle);
      expect(tooltipOf(tester)?.message, longTitle);
      await unmountMission(tester);
    });

    testWidgets('on a phone a long press shows it whole', (tester) async {
      await pump(tester, width: 360, phone: true, title: longTitle);
      final tip = tooltipOf(tester);
      expect(tip?.message, longTitle);
      expect(
        tip?.triggerMode ?? TooltipTriggerMode.longPress,
        TooltipTriggerMode.longPress,
      );
      await tester.longPress(find.byType(TruncatedText).first);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text(longTitle), findsNWidgets(2));
      await settleMission(tester);
      await unmountMission(tester);
    });
  });
}
