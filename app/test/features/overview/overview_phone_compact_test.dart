import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/overview/application/overview_batch.dart';
import 'package:karmashala/src/features/overview/presentation/overview_session_parts.dart';
import 'package:karmashala_ui/tokens.dart';

import 'mission_fixture.dart';

/// **The dashboard's tree on a phone is as compact as the rest of the app**
/// (owner, 2026-10-14): one frame per card, the title beside its avatar,
/// one pick box and only while picking, a tight state row, and the
/// composer and close buttons the size of the app's compact controls with
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

  Finder titleOf(String id) => find
      .descendant(
        of: byKey('overview-card:$id'),
        matching: byKey('overview-card-title:$id'),
      )
      .first;

  // A session alone, at work and ready; a family's root.
  const solos = ['ks-release', 'web-blog', 'beej-ci'];
  const family = 'ks-r32';

  testWidgets('a session alone is one frame: no family frame around its '
      'card', (tester) async {
    await pump(tester);
    for (final id in solos) {
      await reveal(tester, byKey('overview-family:$id'));
      final frame = tester.widget<Container>(byKey('overview-family:$id'));
      expect(frame.decoration, isNull, reason: id);
      expect(frame.padding, anyOf(isNull, EdgeInsets.zero), reason: id);
    }
    await unmountMission(tester);
  });

  testWidgets('a family keeps its frame, and its root card inside is not a '
      'second bordered box', (tester) async {
    await pump(tester);
    await reveal(tester, byKey('overview-card:$family'));
    final frame = tester.widget<Container>(byKey('overview-family:$family'));
    expect(frame.decoration, isNotNull);
    final card = tester.widget<Material>(byKey('overview-card:$family'));
    final shape = card.shape! as RoundedRectangleBorder;
    expect(shape.side, BorderSide.none);
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

  testWidgets('the state row is one tight row from the title\'s start, ⋯ at '
      'its end', (tester) async {
    await pump(tester);
    for (final id in ['ks-release', 'web-blog']) {
      await reveal(tester, titleOf(id));
      final title = tester.getRect(titleOf(id));
      final chip = tester.getRect(
        find
            .descendant(
              of: byKey('overview-card:$id'),
              matching: find.byType(OverviewStatePill),
            )
            .first,
      );
      final menu = tester.getRect(
        find
            .descendant(
              of: byKey('overview-card:$id'),
              matching: byKey('overview-card-menu:$id'),
            )
            .first,
      );
      final card = tester.getRect(byKey('overview-card:$id'));
      expect(chip.left, closeTo(title.left, 1), reason: id);
      expect(chip.top, greaterThanOrEqualTo(title.bottom), reason: id);
      // ⋯ ends the row, at the card's end.
      expect(menu.center.dy, closeTo(chip.center.dy, 1), reason: id);
      expect(card.right - menu.right, lessThanOrEqualTo(Insets.md), reason: id);
    }
    await unmountMission(tester);
  });

  testWidgets('the composer and the close buttons are compact to see, a '
      'thumb\'s target to hit', (tester) async {
    await pump(tester);
    for (final id in ['web-blog', 'ks-release']) {
      final field = find.descendant(
        of: byKey('overview-card:$id'),
        matching: find.byType(InputDecorator),
      );
      await reveal(tester, field);
      expect(
        tester.getSize(field).height,
        lessThanOrEqualTo(Touch.compactControl),
        reason: id,
      );
      final send = byKey('overview-composer-send:$id');
      expect(tester.getSize(send).height, greaterThanOrEqualTo(Touch.target));
      expect(tester.getSize(send).width, greaterThanOrEqualTo(Touch.target));
    }
    for (final key in [
      'overview-done-archive:web-blog',
      'overview-merge:web-blog',
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
      await reveal(tester, byKey('overview-card:$id'));
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

  testWidgets('ready cards sit close: one small gap between them', (
    tester,
  ) async {
    await pump(tester, size: const Size(412, 3600));
    final a = tester.getRect(byKey('overview-family:web-blog'));
    final b = tester.getRect(byKey('overview-family:beej-ci'));
    final (top, bottom) = a.top < b.top ? (a, b) : (b, a);
    expect(bottom.top - top.bottom, lessThanOrEqualTo(Insets.sm));
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
