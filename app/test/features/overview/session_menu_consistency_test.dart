import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/widgets/status_strip.dart';
import 'package:karmashala/src/features/explorer/presentation/session_row_menu.dart';
import 'package:karmashala/src/features/overview/application/overview_providers.dart';
import 'package:karmashala/src/features/overview/application/overview_tiles.dart';
import 'package:karmashala/src/features/overview/presentation/overview_peek.dart';

import 'mission_fixture.dart';

/// **One session menu, everywhere** (round 66, owner, 2026-10-08: "we need
/// consistency across the app"): a dashboard card's ⋯ and right-click, the
/// peek's ⋯, a sub-session row, the session's sheet and the sidebar's row
/// all hold the shared verbs, in the one order, after their own group — so a
/// verb added once shows everywhere and nothing drifts.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('ks-r66-menu'));
  tearDown(() => dir.deleteSync(recursive: true));

  const id = 'ks-r32';

  /// The shared verbs drawn on screen, top to bottom, by their keys.
  List<String> shared(WidgetTester tester, {String prefix = 'session-menu:'}) {
    final found = find.byWidgetPredicate(
      (w) =>
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith(prefix),
    );
    final elements = found.evaluate().toList()
      ..sort(
        (a, b) => tester
            .getTopLeft(find.byElementPredicate((e) => e == a))
            .dy
            .compareTo(
              tester.getTopLeft(find.byElementPredicate((e) => e == b)).dy,
            ),
      );
    return [
      for (final element in elements)
        (element.widget.key! as ValueKey<String>).value
            .substring(prefix.length)
            .replaceFirst(RegExp(r'^terminal:.*'), 'terminal'),
    ];
  }

  /// Every value in [kSessionMenuOrder]'s order, and the verbs every native
  /// session is offered all there.
  void expectSharedOrder(List<String> values, {required String surface}) {
    final shared = [
      for (final v in values)
        if (kSessionMenuOrder.contains(v)) v,
    ];
    final indices = [for (final v in shared) kSessionMenuOrder.indexOf(v)];
    expect(
      indices,
      [...indices]..sort(),
      reason: '$surface: $shared out of the shared order',
    );
    for (final always in const [
      'open',
      'continue-with',
      'subagents',
      'rename',
      'changed-files',
      'copy-id',
      'more',
      'delete',
    ]) {
      expect(shared, contains(always), reason: '$surface lacks $always');
    }
  }

  Future<ProviderContainer> pumpBoard(
    WidgetTester tester, {
    Widget? home,
    Size size = const Size(1440, 900),
    bool phone = false,
  }) => pumpMission(
    tester,
    fixture: MissionFixture.full(),
    prefsDir: dir,
    size: size,
    phone: phone,
    home: home,
  );

  Future<void> dismiss(WidgetTester tester) async {
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settleMission(tester);
    expect(find.byKey(const ValueKey('session-menu:open')), findsNothing);
  }

  testWidgets('a dashboard card\'s ⋯: its own group, then the shared verbs', (
    tester,
  ) async {
    await pumpBoard(tester);
    final menu = find.byKey(const ValueKey('overview-card-menu:$id'));
    await tester.scrollUntilVisible(menu, 200, scrollable: hybridList);
    await tester.tap(menu);
    await settleMission(tester);
    final values = shared(tester);
    expectSharedOrder(values, surface: 'card ⋯');
    // The card's own Pin is first, above the rule.
    final pin = tester.getTopLeft(
      find.byKey(const ValueKey('overview-card-menu:pin')),
    );
    final open = tester.getTopLeft(
      find.byKey(const ValueKey('session-menu:open')),
    );
    expect(pin.dy, lessThan(open.dy));
    expect(find.text('Pin to the top'), findsOneWidget);
    expect(find.text('Detach from parent'), findsNothing, reason: 'no parent');
    await dismiss(tester);

    // A right-click on the card opens the same menu.
    final card = tester.getRect(
      find.byKey(const ValueKey('overview-card:$id')),
    );
    await tester.tapAt(card.center, buttons: kSecondaryButton);
    await settleMission(tester);
    expect(shared(tester), values);
    await dismiss(tester);
    await unmountMission(tester);
  });

  testWidgets('the peek\'s ⋯ and a sub-session row keep the same order', (
    tester,
  ) async {
    await pumpBoard(
      tester,
      home: Scaffold(
        body: Consumer(
          builder: (context, ref, _) {
            final card = overviewCardOf(ref.watch(overviewBoardProvider), id);
            if (card == null) return const SizedBox.shrink();
            return OverviewPeek(card: card, onClose: () {});
          },
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('overview-peek-more')));
    await settleMission(tester);
    final peek = shared(tester);
    expectSharedOrder(peek, surface: 'peek ⋯');
    await dismiss(tester);

    // The session's sheet lists the same verbs as rows.
    final fold = find.byKey(StatusStrip.foldKey);
    if (fold.evaluate().isNotEmpty) {
      await tester.tap(fold);
      await settleMission(tester);
      final rows = shared(tester, prefix: 'session-list:');
      expect(
        [
          for (final v in rows)
            if (kSessionMenuOrder.contains(v)) v,
        ],
        [
          for (final v in peek)
            if (kSessionMenuOrder.contains(v)) v,
        ],
        reason: 'the sheet and the peek ⋯ disagree',
      );
      await dismiss(tester);
    }

    // A sub-session's row: right-click.
    await tester.tap(
      find.byKey(const ValueKey('overview-peek-tab:subSessions')),
    );
    await settleMission(tester);
    await tester.tap(
      find.byKey(const ValueKey('overview-sub:ks-r32-sub0')),
      buttons: kSecondaryButton,
    );
    await settleMission(tester);
    expectSharedOrder(shared(tester), surface: 'sub-session row');
    await dismiss(tester);
    await unmountMission(tester);
  });

  testWidgets('the sidebar\'s row menu is the same list, its own group first', (
    tester,
  ) async {
    late List<PopupMenuEntry<String>> sidebar;
    late List<PopupMenuEntry<String>> plain;
    await pumpBoard(
      tester,
      home: Consumer(
        builder: (context, ref, _) {
          final session = overviewCardOf(
            ref.watch(overviewBoardProvider),
            id,
          )?.entry.native;
          if (session != null) {
            sidebar = nativeSessionMenuItems(
              ref,
              session,
              pinned: false,
              hasSections: true,
              terminals: const [],
            );
            plain = sessionMenuItems(ref, session, terminals: const []);
          }
          return const SizedBox.shrink();
        },
      ),
    );
    List<String> values(List<PopupMenuEntry<String>> items) => [
      for (final item in items)
        if (item is PopupMenuItem<String> &&
            kSessionMenuOrder.contains(item.value))
          item.value!,
    ];
    expect(values(sidebar), values(plain));
    expectSharedOrder(values(plain), surface: 'sidebar');
    // The sidebar's own verbs come first, above a rule.
    final firstShared = sidebar.indexWhere(
      (i) => i is PopupMenuItem<String> && i.value == 'open',
    );
    expect(sidebar[firstShared - 1], isA<PopupMenuDivider>());
    expect(
      [
        for (final i in sidebar.take(firstShared))
          if (i is PopupMenuItem<String>) i.value,
      ],
      ['pin', 'sections', 'select'],
    );
    await unmountMission(tester);
  });
}
