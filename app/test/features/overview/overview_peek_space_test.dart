import 'dart:io';

import 'package:flutter/gestures.dart' show HitTestResult, kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/overview/application/overview_providers.dart';
import 'package:karmashala/src/features/overview/presentation/overview_tab_view.dart';
import 'package:karmashala_ui/tokens.dart';

import 'mission_fixture.dart';

/// **The dashboard's chat shares the space**: wherever it opens beside the
/// board it takes its own room, and the board reflows in what is left —
/// never covered, never cut off (owner, 2026-10-13).
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ks-peek-space');
  });
  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } on FileSystemException {
      // The prefs file may still be held open on Windows; the OS sweeps temp.
    }
  });

  final board = find.byKey(const ValueKey('overview-board-space'));
  final peek = find.byKey(const ValueKey('overview-peek'));
  final resizer = find.byKey(const ValueKey('overview-peek-resizer'));
  final trees = find.byWidgetPredicate(
    (w) =>
        w.key is ValueKey<String> &&
        (w.key! as ValueKey<String>).value.startsWith('overview-family:'),
  );

  Future<void> openPeek(
    WidgetTester tester,
    Size size, {
    double scale = 1,
  }) async {
    await pumpMission(
      tester,
      fixture: MissionFixture.full(),
      prefsDir: dir,
      size: size,
      textScale: scale,
    );
    final open = find.text('Round 21 · ACP sessions').first;
    await tester.scrollUntilVisible(open, 200, scrollable: hybridList);
    await tester.tap(open);
    await settleMission(tester);
  }

  /// Whether a tap at [tree]'s centre lands on it, not on what covers it.
  bool tappable(WidgetTester tester, Finder tree) {
    final result = HitTestResult();
    tester.binding.hitTestInView(
      result,
      tester.getCenter(tree),
      tester.view.viewId,
    );
    final box = tester.renderObject(tree);
    return result.path.any((entry) => entry.target == box);
  }

  Future<void> expectSharesSpace(WidgetTester tester) async {
    expect(peek, findsOneWidget);
    expect(find.byKey(const ValueKey('overview-peek-overlay')), findsNothing);
    final boardRect = tester.getRect(board);
    final peekRect = tester.getRect(peek);
    expect(boardRect.overlaps(peekRect), isFalse);
    expect(boardRect.right, lessThanOrEqualTo(peekRect.left));
    expect(tester.takeException(), isNull);

    await tester.scrollUntilVisible(trees.first, 200, scrollable: hybridList);
    await settleMission(tester);
    final tree = trees.first;
    final treeRect = tester.getRect(tree);
    expect(treeRect.left, greaterThanOrEqualTo(boardRect.left));
    expect(treeRect.right, lessThanOrEqualTo(boardRect.right));
    expect(tappable(tester, tree), isTrue);

    // Everything can be scrolled to, and nothing overflows on the way.
    await tester.drag(hybridList, const Offset(0, -6000));
    await settleMission(tester);
    expect(tester.takeException(), isNull);
  }

  for (final width in [700.0, 900.0, 1100.0, 1400.0]) {
    testWidgets('${width.toInt()} px: the chat takes its own room', (
      tester,
    ) async {
      await openPeek(tester, Size(width, 900));
      await expectSharesSpace(tester);
      await unmountMission(tester);
    });
  }

  testWidgets('900 px at 1.6x text: the chat still takes its own room', (
    tester,
  ) async {
    await openPeek(tester, const Size(900, 900), scale: 1.6);
    await expectSharesSpace(tester);
    await unmountMission(tester);
  });

  group('the space inside a card is the card', () {
    String idOf(Finder tree) =>
        (tree.evaluate().first.widget.key! as ValueKey<String>).value.substring(
          'overview-family:'.length,
        );

    /// A gap in [tree]'s footer, or with [edge] the padding under it.
    Offset gap(WidgetTester tester, Finder tree, {bool edge = false}) {
      final card = tester.getRect(tree);
      return Offset(
        card.left + card.width * 0.3,
        card.bottom - (edge ? Insets.xs / 2 : Touch.target / 2 + Insets.xs),
      );
    }

    Future<ProviderContainer> board1440(WidgetTester tester) => pumpMission(
      tester,
      fixture: MissionFixture.full(),
      prefsDir: dir,
      size: const Size(1440, 900),
    );

    testWidgets('a footer gap opens its chat', (tester) async {
      final c = await board1440(tester);
      await tester.tapAt(gap(tester, trees.first));
      await settleMission(tester);
      expect(c.read(overviewFocusProvider).peeked, idOf(trees.first));
      await unmountMission(tester);
    });

    testWidgets('with a chat open, it moves the chat and does not close it', (
      tester,
    ) async {
      final c = await board1440(tester);
      final other = idOf(trees.at(1));
      c.read(overviewFocusProvider.notifier).peek(idOf(trees.first));
      await settleMission(tester);
      await tester.tapAt(
        gap(tester, find.byKey(ValueKey('overview-family:$other')), edge: true),
      );
      await settleMission(tester);
      expect(c.read(overviewFocusProvider).peeked, other);
      await unmountMission(tester);
    });

    testWidgets('a secondary tap there opens the card menu', (tester) async {
      final c = await board1440(tester);
      await tester.tapAt(gap(tester, trees.first), buttons: kSecondaryButton);
      await settleMission(tester);
      expect(c.read(overviewFocusProvider).peeked, isNull);
      expect(find.byKey(const ValueKey('session-menu:archive')), findsWidgets);
      await unmountMission(tester);
    });
  });

  testWidgets('narrow, the peek gives way first, down to its minimum', (
    tester,
  ) async {
    await openPeek(tester, const Size(700, 900));
    final peekWidth = tester.getSize(peek).width;
    expect(peekWidth, lessThan(Chrome.peekWidth));
    expect(peekWidth, greaterThanOrEqualTo(Chrome.peekMinWidth));
    expect(
      tester.getSize(board).width,
      greaterThanOrEqualTo(Chrome.boardMinWidth),
    );
    await unmountMission(tester);
  });

  testWidgets('below board and peek minimums, the chat is a full sheet', (
    tester,
  ) async {
    const size = Size(660, 900);
    expect(overviewPeekModeAt(size.width), OverviewPeekMode.sheet);
    await openPeek(tester, size);
    expect(peek, findsOneWidget);
    expect(tester.getSize(peek).width, size.width);
    expect(board, findsNothing);
    expect(tester.takeException(), isNull);
    await unmountMission(tester);
  });

  for (final width in [900.0, 1100.0, 1400.0]) {
    testWidgets('${width.toInt()} px: the resizer stays within its bounds', (
      tester,
    ) async {
      await openPeek(tester, Size(width, 900));
      expect(resizer, findsOneWidget);
      await tester.drag(resizer, const Offset(-3000, 0));
      await settleMission(tester);
      expect(
        tester.getSize(peek).width,
        lessThanOrEqualTo(Chrome.peekMaxWidth),
      );
      expect(
        tester.getSize(board).width,
        greaterThanOrEqualTo(Chrome.boardMinWidth),
      );
      await tester.drag(resizer, const Offset(3000, 0));
      await settleMission(tester);
      expect(
        tester.getSize(peek).width,
        greaterThanOrEqualTo(Chrome.peekMinWidth),
      );
      expect(tester.takeException(), isNull);
      await unmountMission(tester);
    });
  }
}
