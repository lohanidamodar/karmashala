import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/overview/application/overview_reads.dart';
import 'package:karmashala/src/features/overview/application/overview_quick_message.dart';
import 'package:karmashala/src/features/overview/application/overview_seen.dart';
import 'package:karmashala/src/features/overview/application/overview_providers.dart';
import 'package:karmashala/src/features/overview/presentation/overview_card_parts.dart';
import 'package:karmashala/src/features/overview/presentation/session_avatar.dart';
import 'package:karmashala_ui/tokens.dart';

import 'mission_fixture.dart';

/// Records what a card's footer sends; throws instead while [fail] is set.
class _SpyMessage extends OverviewQuickMessage {
  _SpyMessage(super.ref);

  final sent = <(String, String)>[];
  String? fail;

  @override
  Future<QuickMessageSent> send(
    String sessionId,
    String text, {
    String? requestId,
  }) async {
    if (fail case final reason?) throw StateError(reason);
    sent.add((sessionId, text));
    return QuickMessageSent(requestId: requestId ?? 'key-${sent.length}');
  }
}

/// **A family card's footer** (round 119): its primary action at the card's
/// end, Open chat from the title's edge, the new count beside the title, and
/// Reply turning the footer into a one-line message box in place.
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ks-card-footer');
  });
  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } on FileSystemException {
      // The prefs file may still be held open on Windows; the OS sweeps temp.
    }
  });

  Finder byKey(String key) => find.byKey(ValueKey(key));

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    Size size = const Size(1440, 1400),
    double textScale = 1,
    MissionFixture? fixture,
  }) => pumpMission(
    tester,
    fixture: fixture ?? MissionFixture.full(),
    prefsDir: dir,
    size: size,
    phone: size.width < WidthClass.mediumMin,
    textScale: textScale,
    overrides: [overviewQuickMessageProvider.overrideWith(_SpyMessage.new)],
  );

  _SpyMessage spy(ProviderContainer c) =>
      c.read(overviewQuickMessageProvider) as _SpyMessage;

  Future<void> reveal(WidgetTester tester, Finder finder) async {
    await tester.scrollUntilVisible(finder, 200, scrollable: hybridList);
    await tester.ensureVisible(finder);
    await settleMission(tester);
  }

  /// Every family card on the board, by root id, from the top left of the
  /// card replied to: a focused field may scroll the board into sight, which
  /// moves no family against another.
  Map<String, Rect> families(WidgetTester tester) {
    final origin = tester.getTopLeft(byKey('overview-family:ks-r30'));
    return {
      for (final element
          in find
              .byWidgetPredicate(
                (w) => switch (w.key) {
                  ValueKey<String>(:final value) => value.startsWith(
                    'overview-family:',
                  ),
                  _ => false,
                },
              )
              .evaluate())
        (element.widget.key! as ValueKey<String>).value: tester
            .getRect(find.byKey(element.widget.key!))
            .shift(-origin),
    };
  }

  /// What a button draws, not its padded target.
  Rect face(WidgetTester tester, String key) => tester.getRect(
    find.descendant(of: byKey(key), matching: find.byType(Material)).first,
  );

  Future<void> openReply(WidgetTester tester, String id) async {
    await reveal(tester, byKey('overview-family-reply:$id'));
    await tester.tap(byKey('overview-family-reply:$id'));
    await settleMission(tester);
  }

  bool focused(WidgetTester tester, String id) => tester
      .widget<EditableText>(
        find.descendant(
          of: byKey('overview-composer:$id'),
          matching: find.byType(EditableText),
        ),
      )
      .focusNode
      .hasFocus;

  for (final width in const [1440.0, 390.0]) {
    final size = Size(width, width > 600 ? 1400 : 844);
    final pad = width > 600 ? Insets.md : Insets.sm;

    testWidgets('${width.toInt()} px: the primary action sits at the card\'s '
        'end, and the footer starts where the title does', (tester) async {
      await pump(tester, size: size);
      for (final (id, primary) in const [
        ('ks-r30', 'overview-family-reply:ks-r30'),
        ('ks-r32', 'overview-end:ks-r32'),
        ('ks-r21', 'overview-family-review:ks-r21'),
        ('ks-r29', 'overview-done-archive:ks-r29'),
      ]) {
        await reveal(tester, byKey(primary));
        final card = tester.getRect(byKey('overview-family:$id'));
        final button = face(tester, primary);
        expect(
          card.right - button.right,
          lessThanOrEqualTo(pad + 1),
          reason: '$id: its primary ends at the card\'s padding',
        );
        // Its end lines up with the state pill's slot above it.
        final state = tester.getRect(byKey('overview-family-state:$id'));
        expect(button.right, closeTo(state.right, 1), reason: id);
        final title = tester.getTopLeft(byKey('overview-card-title:$id'));
        final open = tester.getTopLeft(
          find.descendant(
            of: byKey('overview-family-open:$id'),
            matching: find.byType(Text),
          ),
        );
        expect(open.dx, closeTo(title.dx, 1), reason: '$id: Open chat');
        // ⋯ is a button's face, as tall as the primary beside it.
        expect(
          face(tester, 'overview-card-menu:$id').height,
          closeTo(button.height, 1),
          reason: '$id: ⋯',
        );
      }
      expect(tester.takeException(), isNull);
      await unmountMission(tester);
    });

    testWidgets('${width.toInt()} px: the new count follows the title', (
      tester,
    ) async {
      final now = MissionFixture.now;
      final c = await pump(
        tester,
        size: size,
        fixture: MissionFixture(
          activity: MissionFixture.realisticActivity(),
          glances: {
            'ks-r30': OverviewGlance(
              messageTimes: [
                for (final m in [20, 10, 5]) now.subtract(Duration(minutes: m)),
              ],
            ),
          },
        ),
      );
      c
          .read(overviewSeenProvider.notifier)
          .markSeen('ks-r30', now.subtract(const Duration(minutes: 25)));
      await settleMission(tester);
      final badge = byKey('overview-new:ks-r30');
      await reveal(tester, badge);
      final title = tester.getRect(byKey('overview-card-title:ks-r30'));
      expect(
        tester.getRect(badge).left - title.right,
        lessThanOrEqualTo(Insets.xs + 1),
      );
      expect(tester.takeException(), isNull);
      await unmountMission(tester);
    });

    testWidgets('${width.toInt()} px: Reply opens a message box in place — no '
        'family moves or resizes — Enter sends and closes it, Esc closes '
        'it', (tester) async {
      final c = await pump(tester, size: size);
      await reveal(tester, byKey('overview-family-reply:ks-r30'));
      final before = families(tester);
      await tester.tap(byKey('overview-family-reply:ks-r30'));
      await settleMission(tester);
      final field = byKey('overview-composer:ks-r30');
      expect(field, findsOneWidget);
      expect(focused(tester, 'ks-r30'), isTrue, reason: 'the keys go in');
      expect(families(tester), before, reason: 'nothing moves');
      // The box starts at the title's edge.
      expect(
        tester.getTopLeft(field).dx,
        closeTo(tester.getTopLeft(byKey('overview-card-title:ks-r30')).dx, 1),
      );

      await tester.enterText(field, 'Run the webhook tests again');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settleMission(tester);
      expect(spy(c).sent, [('ks-r30', 'Run the webhook tests again')]);
      expect(field, findsNothing, reason: 'sending puts the buttons back');
      expect(byKey('overview-family-reply:ks-r30'), findsOneWidget);
      expect(families(tester), before);

      await tester.tap(byKey('overview-family-reply:ks-r30'));
      await settleMission(tester);
      await tester.enterText(field, 'never mind');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settleMission(tester);
      expect(field, findsNothing, reason: 'Esc puts the buttons back');
      expect(spy(c).sent, hasLength(1));

      await tester.tap(byKey('overview-family-reply:ks-r30'));
      await settleMission(tester);
      await tester.tap(byKey('overview-composer-cancel:ks-r30'));
      await settleMission(tester);
      expect(field, findsNothing, reason: 'Cancel puts the buttons back');
      expect(families(tester), before);
      expect(tester.takeException(), isNull);
      await unmountMission(tester);
    });
  }

  testWidgets('a send that fails says so in the box and keeps the words', (
    tester,
  ) async {
    final c = await pump(tester);
    await openReply(tester, 'ks-r30');
    final before = families(tester);
    spy(c).fail = 'The host is offline';
    final field = byKey('overview-composer:ks-r30');
    await tester.enterText(field, 'Run the webhook tests again');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settleMission(tester);
    expect(byKey('overview-composer-said:ks-r30'), findsOneWidget);
    expect(find.text('Not sent'), findsOneWidget);
    expect(find.text('Run the webhook tests again'), findsOneWidget);
    expect(focused(tester, 'ks-r30'), isTrue);
    expect(families(tester), before, reason: 'the failure moves nothing');

    // Sent again once the host is back: the same words, then closed.
    spy(c).fail = null;
    await tester.tap(byKey('overview-composer-send:ks-r30'));
    await settleMission(tester);
    expect(spy(c).sent, [('ks-r30', 'Run the webhook tests again')]);
    expect(field, findsNothing);
    await unmountMission(tester);
  });

  testWidgets('390 px: a keyboard coming up leaves the box in sight', (
    tester,
  ) async {
    await pump(tester, size: const Size(390, 844));
    await openReply(tester, 'ks-r30');
    // The box at the foot of the screen, where the keyboard comes up.
    await tester.ensureVisible(byKey('overview-composer:ks-r30'));
    unawaited(
      Scrollable.ensureVisible(
        tester.element(byKey('overview-composer:ks-r30')),
        alignment: 1,
      ),
    );
    await settleMission(tester);
    const keyboard = 320.0;
    expect(
      tester.getRect(byKey('overview-composer:ks-r30')).bottom,
      greaterThan(844 - keyboard),
      reason: 'the keyboard would cover it where it was',
    );
    tester.view.viewInsets = const FakeViewPadding(bottom: keyboard);
    addTearDown(tester.view.resetViewInsets);
    await settleMission(tester);
    final box = tester.getRect(byKey('overview-composer:ks-r30'));
    expect(box.bottom, lessThanOrEqualTo(844 - keyboard));
    expect(box.top, greaterThanOrEqualTo(0));
    expect(tester.takeException(), isNull);
    await unmountMission(tester);
  });

  for (final width in const [360.0, 1440.0]) {
    for (final scale in const [1.0, 1.6]) {
      testWidgets('${width.toInt()} px at ${scale}x: nothing overflows with '
          'the box open', (tester) async {
        await pump(
          tester,
          size: Size(width, width > 600 ? 1400 : 800),
          textScale: scale,
        );
        await openReply(tester, 'ks-r30');
        await tester.enterText(
          byKey('overview-composer:ks-r30'),
          'A long enough message to fill the one line of the box and more',
        );
        await settleMission(tester);
        final card = tester.getRect(byKey('overview-family:ks-r30'));
        final send = tester.getRect(byKey('overview-composer-send:ks-r30'));
        expect(send.right, lessThanOrEqualTo(card.right));
        expect(tester.takeException(), isNull);
        await unmountMission(tester);
      });
    }
  }

  group('one outline', () {
    Finder pill(String id) => byKey('overview-tree-pill:$id');

    BorderSide edgeOf(WidgetTester tester, String id) =>
        (tester
                    .widget<Material>(
                      find
                          .ancestor(
                            of: pill(id),
                            matching: find.byType(Material),
                          )
                          .first,
                    )
                    .shape!
                as RoundedRectangleBorder)
            .side;

    BoxDecoration? ringOf(WidgetTester tester, String id) =>
        tester
                .widget<Container>(byKey('overview-family:$id'))
                .foregroundDecoration
            as BoxDecoration?;

    Color borderOf(WidgetTester tester, String id) =>
        ((tester.widget<Container>(byKey('overview-family:$id')).decoration!
                        as BoxDecoration)
                    .border!
                as Border)
            .top
            .color;

    /// No ring is drawn round a row or a header on top of its own outline.
    Finder extraRings() => find.byWidgetPredicate(
      (w) => switch (w.key) {
        ValueKey<String>(:final value) => value.startsWith(
          'overview-link-lit:',
        ),
        _ => false,
      },
    );

    const subs = ['ks-r32-sub0', 'ks-r32-sub1', 'ks-r32-sub2'];

    testWidgets('a pointer over the parent: the card outlines along its own '
        'shape, each sub-session\'s row turns its own outline the accent, and '
        'no second line or header box is drawn', (tester) async {
      await pump(tester);
      final head = byKey('overview-family-head:ks-r32');
      await reveal(tester, head);
      final scheme = Theme.of(tester.element(head)).colorScheme;
      expect(borderOf(tester, 'ks-r32'), scheme.outlineVariant);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: tester.getCenter(head));
      await settleMission(tester);

      expect(extraRings(), findsNothing);
      expect(borderOf(tester, 'ks-r32'), scheme.outline);
      expect(ringOf(tester, 'ks-r32')?.border, isNull);
      for (final id in subs) {
        final side = edgeOf(tester, id);
        expect(side.color, scheme.primary, reason: id);
        expect(side.width, StateLayers.focusRingWidth * 2, reason: id);
      }
      // The header draws no hover box of its own behind the title.
      final ink = tester.widget<InkWell>(head);
      expect(
        ink.overlayColor?.resolve({WidgetState.hovered}),
        Colors.transparent,
      );
      expect(tester.takeException(), isNull);
      await unmountMission(tester);
    });

    testWidgets(
      'a pointer over a sub-session: its row outlines once, its avatar '
      'glows; the parent rings nothing, its avatar glows, its card shows '
      'the hover outline along its own edge',
      (tester) async {
        await pump(tester);
        await reveal(tester, pill('ks-r32-sub1'));
        final scheme = Theme.of(
          tester.element(pill('ks-r32-sub1')),
        ).colorScheme;
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        addTearDown(mouse.removePointer);
        await mouse.addPointer(location: tester.getCenter(pill('ks-r32-sub1')));
        await settleMission(tester);
        expect(extraRings(), findsNothing);
        expect(edgeOf(tester, 'ks-r32-sub1').color, scheme.outline);
        expect(ringOf(tester, 'ks-r32')?.border, isNull);
        expect(borderOf(tester, 'ks-r32'), scheme.outline);
        bool glows(String id) => tester
            .widget<SessionAvatar>(
              find.byWidgetPredicate(
                (w) => w is SessionAvatar && w.card.id == id,
              ),
            )
            .glow;
        expect(glows('ks-r32-sub1'), isTrue);
        expect(glows('ks-r32'), isTrue, reason: 'the quiet "its parent"');
        expect(glows('ks-r32-sub2'), isFalse);
        expect(tester.takeException(), isNull);
        await unmountMission(tester);
      },
    );

    testWidgets('the keys (J/K) select with the same one accent outline, on '
        'the card and on a row', (tester) async {
      final c = await pump(tester);
      await reveal(tester, pill('ks-r32-sub1'));
      final scheme = Theme.of(tester.element(pill('ks-r32-sub1'))).colorScheme;
      c.read(overviewFocusProvider.notifier).select('ks-r32');
      await settleMission(tester);
      final ring = ringOf(tester, 'ks-r32')!.border!.top;
      expect(ring.color, scheme.primary);
      expect(ring.width, StateLayers.focusRingWidth * 2);
      expect(extraRings(), findsNothing);

      c.read(overviewFocusProvider.notifier).select('ks-r32-sub1');
      await settleMission(tester);
      expect(ringOf(tester, 'ks-r32')?.border, isNull);
      final side = edgeOf(tester, 'ks-r32-sub1');
      expect(side.color, scheme.primary);
      expect(side.width, ring.width, reason: 'the same ring as the card');
      expect(extraRings(), findsNothing);
      await unmountMission(tester);
    });
  });

  test('a preview line is plain text: links by their label', () {
    expect(
      overviewPlain(
        'It sent its report on [#6980](https://github.com/o/r/pull/6980). '
        'See <https://example.com/x> and ![shot](a.png).\n'
        '- **Bold** and *soft* and `code` and ~~gone~~\n'
        '## Next\n> quoted',
      ),
      'It sent its report on #6980. See https://example.com/x and shot. '
      'Bold and soft and code and gone Next quoted',
    );
    expect(
      overviewPlain('snake_case_name stays, -40 stays'),
      'snake_case_name stays, -40 stays',
    );
  });
}
