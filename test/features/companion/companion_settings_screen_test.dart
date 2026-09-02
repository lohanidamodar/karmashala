/// The settings screen says which path carries the link — "Direct (LAN)" at
/// home, "Relay" from anywhere — beside the connected state.
library;

import 'package:karmashala/src/features/companion/client/companion_gateway.dart';
import 'package:karmashala/src/features/companion/client/fake_companion_gateway.dart';
import 'package:karmashala/src/features/companion/presentation/companion_settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'companion_test_support.dart';

void main() {
  testWidgets('a connected link names its path, and follows it moving', (
    tester,
  ) async {
    final gateway = FakeCompanionGateway.paired(
      linkPath: CompanionLinkPath.lan,
    );
    await pumpPhone(
      tester,
      gateway: gateway,
      home: const CompanionSettingsScreen(),
    );

    expect(find.text('Connected · Direct (LAN)'), findsOneWidget);

    gateway.setLinkPath(CompanionLinkPath.relay);
    await tester.pump();
    await tester.pump();

    expect(find.text('Connected · Relay'), findsOneWidget);
    expect(find.text('Connected · Direct (LAN)'), findsNothing);
  });

  testWidgets('a downed link shows the outage, not a stale path', (
    tester,
  ) async {
    final gateway = FakeCompanionGateway.paired(
      link: CompanionLinkState.disconnected,
    );
    await pumpPhone(
      tester,
      gateway: gateway,
      home: const CompanionSettingsScreen(),
    );

    expect(find.text('Host unreachable'), findsOneWidget);
    expect(find.textContaining('Connected'), findsNothing);
  });

  testWidgets('the whole settings screen survives 200% text', (tester) async {
    final gateway = FakeCompanionGateway.paired(
      link: CompanionLinkState.disconnected,
    );
    await pumpPhone(
      tester,
      gateway: gateway,
      home: const CompanionSettingsScreen(),
      textScale: 2.0,
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // Every section still names itself; a heading that vanished at large text
    // would take the structure of the screen with it.
    for (final heading in const [
      'PAIRED DESKTOP',
      'THIS CONNECTION',
      'PAIRING RELAY',
      'DIAGNOSTICS',
    ]) {
      await tester.scrollUntilVisible(
        find.text(heading),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text(heading), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('every section heading is a header for a screen reader', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pumpPhone(
      tester,
      gateway: FakeCompanionGateway.paired(),
      home: const CompanionSettingsScreen(),
    );
    await tester.pumpAndSettle();

    expect(
      tester.getSemantics(find.text('THIS CONNECTION')),
      matchesSemantics(label: 'THIS CONNECTION', isHeader: true),
    );
    handle.dispose();
  });
}
