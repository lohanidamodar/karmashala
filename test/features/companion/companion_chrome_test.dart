/// The companion's shared chrome, asserted at phone size and at 200% text.
///
/// Each of these three was hand-written in three to five places before it was
/// a widget, and each had drifted somewhere a user could see it:
///
/// * four app bars took Material's fixed 56px while three grew with the text
///   scale, so at 200% half the app clipped its own screen names;
/// * two of the three bottom sheets were not scroll-controlled, which caps a
///   sheet at half the viewport — and the host switcher put a bare `Column`
///   inside that half;
/// * the Projects tab left 24px under its last row for a 56px floating button.
library;

import 'package:karmashala/src/app/theme/design_tokens.dart';
import 'package:karmashala/src/features/companion/client/companion_gateway.dart';
import 'package:karmashala/src/features/companion/client/fake_companion_gateway.dart';
import 'package:karmashala/src/features/companion/presentation/companion_chrome.dart';
import 'package:karmashala/src/features/companion/presentation/companion_log_screen.dart';
import 'package:karmashala/src/features/companion/presentation/host_switcher_bar.dart';
import 'package:karmashala/src/features/companion/presentation/pairing/pairing_progress_screen.dart';
import 'package:karmashala/src/features/companion/presentation/pairing/scan_qr_screen.dart';
import 'package:karmashala/src/features/companion/presentation/pairing/short_code_screen.dart';
import 'package:karmashala/src/features/companion/presentation/session_list_screen.dart';
import 'package:karmashala/src/features/explorer/presentation/project_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'companion_test_support.dart';

void main() {
  group('the one app bar', () {
    // Every companion screen that has an app bar of its own. The four pairing
    // and diagnostics screens are the ones that used to take Material's fixed
    // height; the list is the whole set so a new screen cannot quietly opt out.
    final screens = <String, Widget Function()>{
      'Diagnostics': () => const CompanionLogScreen(),
      'Type the pairing code': () => const ShortCodeScreen(),
      'Scan the QR code': () =>
          ScanQrScreen(scannerBuilder: (_, _) => const Placeholder()),
      'Pairing': () =>
          PairingProgressScreen(attempt: (g) => g.pairWithCode('WRONG000')),
    };

    for (final entry in screens.entries) {
      testWidgets('${entry.key} fits its title at 100% and grows at 200%', (
        tester,
      ) async {
        await pumpPhone(
          tester,
          gateway: FakeCompanionGateway(),
          home: entry.value(),
        );
        expect(find.text(entry.key), findsOneWidget);
        final small = tester.getSize(find.byType(AppBar)).height;
        expect(small, Touch.appBar);
        expect(tester.takeException(), isNull);

        await pumpPhone(
          tester,
          gateway: FakeCompanionGateway(),
          home: entry.value(),
          textScale: 2.0,
        );
        expect(
          tester.getSize(find.byType(AppBar)).height,
          greaterThan(small),
          reason: 'the bar grows with the text rather than clipping it',
        );
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('the one bottom sheet', () {
    List<CompanionConnection> desktops(int count) => [
      for (var i = 0; i < count; i++)
        CompanionConnection(
          hostId: fakeHostId(i + 1),
          name: 'Desktop number $i',
          active: i == 0,
        ),
    ];

    testWidgets('names itself, and reaches its last row at 200% text', (
      tester,
    ) async {
      final gateway = FakeCompanionGateway.paired(connections: desktops(6));
      await pumpPhone(
        tester,
        gateway: gateway,
        home: const HostSwitcherBar(),
        textScale: 2.0,
      );

      await tester.tap(find.text('Desktop number 0'));
      await tester.pumpAndSettle();
      // Six desktops of two-line names at 200% is far taller than the half
      // viewport Material gives an un-scroll-controlled sheet.
      expect(tester.takeException(), isNull);
      expect(find.text('DESKTOPS'), findsOneWidget);

      await tester.dragUntilVisible(
        find.text('Add a desktop'),
        find.byType(SingleChildScrollView).last,
        const Offset(0, -120),
      );
      await tester.tap(find.text('Add a desktop'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('stays as short as its contents when there are only two', (
      tester,
    ) async {
      final gateway = FakeCompanionGateway.paired(connections: desktops(2));
      await pumpPhone(tester, gateway: gateway, home: const HostSwitcherBar());

      await tester.tap(find.text('Desktop number 0'));
      await tester.pumpAndSettle();

      final sheet = tester.getSize(find.byType(BottomSheet));
      expect(
        sheet.height,
        lessThan(844 * 0.5),
        reason: 'scroll-controlled does not mean full-height',
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('the floating action button gutter', () {
    testWidgets('leaves the last project row clear of the button', (
      tester,
    ) async {
      // Enough projects that the list actually scrolls; the bug only showed
      // at the end of a full list.
      final gateway = FakeCompanionGateway.paired(
        sessions: [
          for (var i = 0; i < 20; i++)
            summary('s$i', project: 'project-$i', projectId: 'p$i'),
        ],
      );
      await pumpPhone(
        tester,
        gateway: gateway,
        home: const SessionListScreen(),
      );

      await tester.drag(find.byType(ProjectCard).first, const Offset(0, -4000));
      await tester.pumpAndSettle();

      final fab = tester.getRect(find.byType(FloatingActionButton));
      final last = tester.getRect(find.byType(ProjectCard).last);
      expect(
        last.bottom,
        lessThanOrEqualTo(fab.top),
        reason: 'the button that starts a session must not sit on top of one',
      );
      expect(companionFabGutter, greaterThanOrEqualTo(Touch.target));
    });
  });

  group('the one section header', () {
    testWidgets('is a header to a screen reader, not just small caps', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpPhone(
        tester,
        gateway: FakeCompanionGateway(),
        home: const CompanionSectionHeader('DIAGNOSTICS'),
      );

      expect(
        tester.getSemantics(find.text('DIAGNOSTICS')),
        matchesSemantics(label: 'DIAGNOSTICS', isHeader: true),
      );
      handle.dispose();
    });
  });
}
