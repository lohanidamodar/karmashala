import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/overview/application/overview_batch.dart';
import 'package:karmashala_ui/tokens.dart';

import 'mission_fixture.dart';

/// **The dashboard's families on a phone are as compact as the rest of the
/// app** (owner, 2026-10-14): one frame per family with its avatar inside,
/// the title beside it, one pick box and only while picking, the state in
/// its slot, and footer buttons the size of the app's compact controls with
/// a thumb's hit area kept.
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ks-phone-compact');
  });
  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } on FileSystemException {
      // The prefs file may still be held open on Windows; the OS sweeps temp.
    }
  });

  Finder byKey(String key) => find.byKey(ValueKey(key));

  Future<dynamic> pump(
    WidgetTester tester, {
    Size size = const Size(412, 915),
    double scale = 1,
  }) => pumpMission(
    tester,
    fixture: MissionFixture.full(),
    prefsDir: dir,
    size: size,
    phone: true,
    textScale: scale,
  );

  Future<void> reveal(WidgetTester tester, Finder target) async {
    await tester.scrollUntilVisible(target, 300, scrollable: hybridList);
    await tester.ensureVisible(target);
    await settleMission(tester);
  }

  Finder head(String id) => byKey('overview-family-head:$id');
  Finder titleOf(String id) => find
      .descendant(of: head(id), matching: byKey('overview-card-title:$id'))
      .first;

  // A session alone, at work and ready; a family's root.
  const solos = ['ks-release', 'web-blog', 'beej-ci'];
  const family = 'ks-r32';

  testWidgets('every family is one frame with its avatar inside, and no '
      'second bordered card in it', (tester) async {
    await pump(tester);
    for (final id in [...solos, family]) {
      await reveal(tester, byKey('overview-family:$id'));
      final frame = tester.widget<Container>(byKey('overview-family:$id'));
      expect(frame.decoration, isNotNull, reason: id);
      expect(
        find.descendant(
          of: byKey('overview-family:$id'),
          matching: byKey('overview-card:$id'),
        ),
        findsNothing,
        reason: id,
      );
      final avatar = tester.getRect(byKey('session-avatar:$id'));
      final card = tester.getRect(byKey('overview-family:$id'));
      expect(card.contains(avatar.topLeft), isTrue, reason: id);
    }
    await unmountMission(tester);
  });

  testWidgets('the title starts beside the avatar, not a third of the way '
      'across', (tester) async {
    await pump(tester);
    for (final id in [...solos, family]) {
      await reveal(tester, titleOf(id));
      final avatar = tester.getRect(byKey('session-avatar:$id'));
      final title = tester.getRect(titleOf(id));
      expect(
        title.left - avatar.left,
        lessThanOrEqualTo(Chrome.sessionAvatarCompact + Insets.md),
        reason: id,
      );
      // And clear of it.
      expect(title.left, greaterThanOrEqualTo(avatar.right), reason: id);
    }
    await unmountMission(tester);
  });

  testWidgets('the state sits on the title\'s row, in its slot at the end; '
      '⋯ is in the footer under it', (tester) async {
    await pump(tester);
    for (final id in ['ks-release', 'web-blog']) {
      await reveal(tester, byKey('overview-card-menu:$id'));
      final title = tester.getRect(titleOf(id));
      final slot = tester.getRect(byKey('overview-family-state:$id'));
      final menu = tester.getRect(byKey('overview-card-menu:$id'));
      final card = tester.getRect(byKey('overview-family:$id'));
      expect(slot.center.dy, closeTo(title.center.dy, Insets.sm), reason: id);
      expect(slot.left, greaterThanOrEqualTo(title.left), reason: id);
      expect(card.right - slot.right, lessThanOrEqualTo(Insets.md), reason: id);
      expect(menu.top, greaterThan(title.bottom), reason: id);
    }
    await unmountMission(tester);
  });

  testWidgets('the footer\'s buttons are compact to see, a thumb\'s target '
      'to hit', (tester) async {
    await pump(tester);
    for (final key in [
      'overview-family-open:web-blog',
      'overview-family-reply:web-blog',
      'overview-family-open:ks-release',
      'overview-end:ks-release',
    ]) {
      await reveal(tester, byKey(key));
      final hit = tester.getSize(byKey(key));
      expect(hit.height, greaterThanOrEqualTo(Touch.target), reason: key);
      final face = tester.getSize(
        find.descendant(of: byKey(key), matching: find.byType(Material)).first,
      );
      expect(face.height, lessThanOrEqualTo(Touch.compactControl), reason: key);
    }
    await unmountMission(tester);
  });

  int boxesOf(String id) =>
      find.byKey(ValueKey('overview-select:$id')).evaluate().length +
      find.byKey(ValueKey('overview-tree-select:$id')).evaluate().length;

  testWidgets('no pick box at rest under a thumb; one per card once a '
      'long press starts picking', (tester) async {
    final c = await pump(tester);
    for (final id in solos) {
      await reveal(tester, head(id));
      expect(boxesOf(id), 0, reason: '$id at rest');
    }
    await reveal(tester, titleOf('web-blog'));
    await tester.longPress(titleOf('web-blog'));
    await settleMission(tester);
    expect(c.read(overviewSelectionProvider).contains('web-blog'), isTrue);
    for (final id in [...solos, family, 'ks-r32-sub0']) {
      await reveal(tester, byKey('session-avatar:$id'));
      expect(boxesOf(id), 1, reason: '$id while picking');
    }
    // The avatar's box picks another while picking.
    await reveal(tester, byKey('overview-tree-select:beej-ci'));
    await tester.tap(byKey('overview-tree-select:beej-ci'));
    await settleMission(tester);
    expect(c.read(overviewSelectionProvider).contains('beej-ci'), isTrue);
    await unmountMission(tester);
  });

  testWidgets('families in a lane sit close: one small gap between them', (
    tester,
  ) async {
    await pump(tester, size: const Size(412, 3600));
    final cards = [
      for (final element
          in find
              .byWidgetPredicate(
                (w) =>
                    w is Container &&
                    w.key is ValueKey<String> &&
                    (w.key! as ValueKey<String>).value.startsWith(
                      'overview-family:',
                    ),
              )
              .evaluate())
        tester.getRect(find.byWidget(element.widget)),
    ]..sort((a, b) => a.top.compareTo(b.top));
    expect(cards.length, greaterThan(1));
    final gaps = [
      for (var i = 1; i < cards.length; i++) cards[i].top - cards[i - 1].bottom,
    ];
    // Within a lane one small gap; a lane's header sits between lanes.
    expect(gaps.reduce((a, b) => a < b ? a : b), lessThanOrEqualTo(Insets.sm));
    await unmountMission(tester);
  });

  for (final (width, scale) in [(360.0, 1.0), (360.0, 1.6), (412.0, 1.6)]) {
    testWidgets('${width}px at ${scale}x: nothing overflows', (tester) async {
      await pump(tester, size: Size(width, 6000), scale: scale);
      expect(tester.takeException(), isNull);
      await unmountMission(tester);
    });
  }
}
