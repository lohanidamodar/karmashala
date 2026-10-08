import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/widgets/status_strip.dart';
import 'package:karmashala/src/app/widgets/view_switch.dart';
import 'package:karmashala/src/core/capabilities/capabilities.dart';
import 'package:karmashala/src/features/overview/presentation/overview_session_parts.dart';
import 'package:karmashala/src/features/sessions/presentation/switch_agent_control.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';

import 'mission_fixture.dart';

/// **A slim session header, and a status strip that says it all** (round 59,
/// owner, 2026-10-08): the header is one row with no meta line; on a phone
/// the views are glyphs in that row; every fact the meta line held — the
/// state, the agent, the model, where it runs — is on the strip under the
/// session, which never scrolls or clips and folds what does not fit into
/// +N; and the agent is picked in one place.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('ks-r59-chrome'));
  tearDown(() => dir.deleteSync(recursive: true));

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    required Size size,
    bool phone = false,
    double textScale = 1,
    bool switchesAgent = false,
  }) => pumpMission(
    tester,
    fixture: _fixture(),
    prefsDir: dir,
    size: size,
    phone: phone,
    textScale: textScale,
    overrides: [
      if (switchesAgent)
        serverOfferProvider.overrideWithValue(
          ServerOffer(
            sameMachine: true,
            serverOs: 'windows',
            features: const {'sessions.switchAgent'},
          ),
        ),
    ],
  );

  Future<void> open(WidgetTester tester, {required bool phone}) async {
    final row = phone
        ? find.byKey(const ValueKey('overview-phone-row:ks-r32'))
        : find.text('Round 32 · Overview redesign').first;
    await tester.scrollUntilVisible(row, 300, scrollable: hybridList);
    await tester.ensureVisible(row);
    await tester.pump();
    await tester.tap(row);
    await settleMission(tester);
    // The phone's page slides in; measured once it has landed.
    await tester.pump(const Duration(seconds: 1));
    await settleMission(tester);
    expect(find.byKey(const ValueKey('overview-peek')), findsOneWidget);
  }

  final header = find.byWidgetPredicate(
    (w) =>
        w.key == const ValueKey('overview-peek-bar') ||
        w.runtimeType.toString() == '_PeekHeader',
  );
  final strip = find.byKey(const ValueKey('overview-peek-controls'));
  Finder inStrip(Finder f) => find.descendant(of: strip, matching: f);
  Finder inHeader(Finder f) => find.descendant(of: header, matching: f);

  /// The facts the old meta line carried, by the strip's keys.
  const facts = ['state', 'model', 'agent', 'place'];

  /// [id] drawn on the strip's line, not folded away.
  bool onLine(WidgetTester tester, String id) => inStrip(
    find.byKey(ValueKey('status-strip:$id')),
  ).hitTestable().evaluate().isNotEmpty;

  /// Every former header fact is on the line or, folded, in +N's sheet.
  Future<void> expectEveryFactReachable(WidgetTester tester) async {
    final folded = [
      for (final id in facts)
        if (!onLine(tester, id)) id,
    ];
    if (folded.isEmpty) return;
    await tester.tap(inStrip(find.byKey(StatusStrip.foldKey)));
    await tester.pumpAndSettle();
    final sheet = find.byKey(const ValueKey('status-strip-sheet'));
    for (final id in folded) {
      expect(
        find.descendant(
          of: sheet,
          matching: find.byKey(ValueKey('status-strip:$id')),
        ),
        findsOneWidget,
        reason: id,
      );
    }
    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
  }

  /// One line, inside the window, nothing overflowing.
  void expectStripFits(WidgetTester tester, Size size) {
    expect(tester.takeException(), isNull);
    final rect = tester.getRect(strip);
    expect(rect.right, lessThanOrEqualTo(size.width));
    // A touch target's height and its top rule: one line, never two.
    expect(rect.height, lessThanOrEqualTo(Touch.target + Insets.xs));
    // The state and the model are never folded.
    expect(onLine(tester, 'state'), isTrue);
    expect(onLine(tester, 'model'), isTrue);
    expect(inStrip(find.text('Opus 5.5')).hitTestable(), findsOneWidget);
    // The fold's count is what is left off the line.
    final fold = inStrip(find.byKey(StatusStrip.foldKey));
    if (fold.evaluate().isNotEmpty) {
      final label = tester.widget<Text>(
        find.descendant(of: fold, matching: find.byType(Text)),
      );
      expect(label.data, startsWith('+'));
    }
  }

  for (final size in const [Size(360, 800), Size(390, 844), Size(412, 915)]) {
    for (final scale in const [1.0, 1.6]) {
      final name = '${size.width.round()} px, text ×$scale';

      testWidgets('$name: one slim row, the views in it, no meta line', (
        tester,
      ) async {
        await pump(tester, size: size, phone: true, textScale: scale);
        await open(tester, phone: true);
        expect(tester.takeException(), isNull);

        final bar = tester.getRect(
          find.byKey(const ValueKey('overview-peek-bar')),
        );
        expect(bar.height, lessThanOrEqualTo(Touch.target + Insets.sm));
        // The state and the meta line are not in the header.
        expect(inHeader(find.byType(OverviewStatePill)), findsNothing);
        expect(
          inHeader(find.byKey(const ValueKey('overview-peek-place'))),
          findsNothing,
        );
        expect(inHeader(find.textContaining('Opus 5.5')), findsNothing);
        // The views: glyphs in the row, not a row of words of their own.
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('overview-peek')),
            matching: find.byWidgetPredicate((w) => w is CompactSegmented),
          ),
          findsNothing,
        );
        final views = find.byKey(const ValueKey('overview-peek-tabs'));
        expect(inHeader(views), findsOneWidget);
        expect(tester.getRect(views).height, lessThanOrEqualTo(bar.height));
        expect(tester.widget<ViewSwitch<Object?>>(views).labelled, isFalse);
        for (final view in const ['chat', 'terminal', 'files']) {
          expect(
            find.byKey(ValueKey('overview-peek-tab:$view')),
            findsOneWidget,
            reason: view,
          );
        }
        expect(find.byTooltip('Files · 3 changed'), findsOneWidget);
        await unmountMission(tester);
      });

      testWidgets('$name: the strip fits one line, every fact reachable', (
        tester,
      ) async {
        await pump(tester, size: size, phone: true, textScale: scale);
        await open(tester, phone: true);
        expectStripFits(tester, size);
        await expectEveryFactReachable(tester);
        expect(tester.takeException(), isNull);
        await unmountMission(tester);
      });
    }
  }

  testWidgets('on a phone every view still opens', (tester) async {
    await pump(tester, size: const Size(390, 844), phone: true);
    await open(tester, phone: true);

    await tester.tap(find.byKey(const ValueKey('overview-peek-tab:files')));
    await settleMission(tester);
    expect(find.text('overview_hybrid_test.dart'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('overview-peek-tab:terminal')));
    await settleMission(tester);
    expect(
      find.text('This session has no terminal open on this machine.'),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('overview-peek-tab:chat')));
    await settleMission(tester);
    expect(
      find.byKey(const ValueKey('overview-peek-chat:ks-r32')),
      findsOneWidget,
    );

    // Sub-sessions, a fourth view, from ⋯.
    await tester.tap(find.byKey(const ValueKey('overview-peek-more')));
    await settleMission(tester);
    await tester.tap(
      find.byKey(const ValueKey('overview-peek-menu:subSessions')),
    );
    await settleMission(tester);
    expect(find.byKey(const ValueKey('overview-peek-subs')), findsOneWidget);
    // The strip is under every view.
    expect(strip, findsOneWidget);
    await unmountMission(tester);
  });

  for (final size in const [Size(768, 900), Size(1100, 800), Size(1440, 900)]) {
    for (final scale in const [1.0, 1.6]) {
      testWidgets('${size.width.round()} px, text ×$scale: the header has no '
          'meta line, the strip fits', (tester) async {
        await pump(tester, size: size, textScale: scale);
        await open(tester, phone: false);
        expect(tester.takeException(), isNull);

        expect(inHeader(find.byType(OverviewStatePill)), findsNothing);
        expect(inHeader(find.textContaining('Opus 5.5')), findsNothing);
        expect(inHeader(find.textContaining('Usage')), findsNothing);
        // The desktop keeps its labelled views.
        expect(
          find.byKey(const ValueKey('overview-peek-tab:files')),
          findsOneWidget,
        );
        expect(find.text('Files · 3'), findsOneWidget);

        final peek = tester.getRect(
          find.byKey(const ValueKey('overview-peek')),
        );
        expectStripFits(tester, Size(peek.right, size.height));
        await expectEveryFactReachable(tester);
        await unmountMission(tester);
      });
    }
  }

  group('the agent is picked in one place', () {
    testWidgets('where the composer switches it, the strip does not name it', (
      tester,
    ) async {
      await pump(tester, size: const Size(1440, 900), switchesAgent: true);
      await open(tester, phone: false);
      expect(
        inStrip(find.byKey(const ValueKey('overview-peek-agent'))),
        findsNothing,
      );
      expect(inStrip(find.byType(SwitchAgentControl)), findsNothing);
      await unmountMission(tester);
    });

    testWidgets('where nothing else names it, the strip does, as a fact', (
      tester,
    ) async {
      await pump(tester, size: const Size(1440, 900));
      await open(tester, phone: false);
      expect(
        inStrip(find.byKey(const ValueKey('overview-peek-agent'))),
        findsOneWidget,
      );
      expect(inStrip(find.byType(SwitchAgentControl)), findsNothing);
      expect(find.byTooltip('Agent: Claude Code'), findsOneWidget);
      await unmountMission(tester);
    });
  });
}

/// [MissionFixture.full] with a terminal pane, so every view is there.
MissionFixture _fixture() {
  final full = MissionFixture.full();
  return MissionFixture(
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
