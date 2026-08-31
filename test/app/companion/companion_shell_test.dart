import 'package:chitragupta/src/app/companion/companion_shell.dart';
import 'package:chitragupta/src/features/companion/client/companion_gateway.dart';
import 'package:chitragupta/src/features/companion/client/fake_companion_gateway.dart';
import 'package:chitragupta/src/features/companion/presentation/pairing/pairing_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../features/companion/companion_test_support.dart';

/// The phone shell: pairing until a host exists, then Sessions / Inbox /
/// Settings under one connection banner — bottom navigation, per the
/// compact-breakpoint contract (CLAUDE.md §6).
void main() {
  testWidgets('an unpaired companion boots straight into pairing', (
    tester,
  ) async {
    await pumpPhone(
      tester,
      gateway: FakeCompanionGateway(),
      home: const CompanionShell(),
    );
    expect(find.byType(PairingScreen), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
  });

  testWidgets('pairing swaps the shell to the tabs, live', (tester) async {
    final gateway = FakeCompanionGateway();
    await pumpPhone(tester, gateway: gateway, home: const CompanionShell());
    expect(find.byType(PairingScreen), findsOneWidget);

    await gateway.pairWithCode(gateway.validShortCode);
    await tester.pump();
    await tester.pump();

    expect(find.byType(NavigationBar), findsOneWidget);
    // The first tab is named for what it lists: the host's projects, each of
    // which opens its own sessions (Loop 82).
    expect(find.text('Projects'), findsWidgets);
    expect(find.text('Inbox'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
  });

  testWidgets('the inbox tab wears the attention count', (tester) async {
    final gateway = FakeCompanionGateway.paired(
      sessions: [
        summary(
          's1',
          attention: CompanionAttention(
            kind: CompanionAttentionKind.needsYou,
            at: DateTime.now().toUtc(),
          ),
        ),
      ],
    );
    await pumpPhone(tester, gateway: gateway, home: const CompanionShell());
    expect(find.byType(Badge), findsOneWidget);
    // Scoped to the badge: the project header also carries a count of its own.
    expect(
      find.descendant(of: find.byType(Badge), matching: find.text('1')),
      findsOneWidget,
    );
  });

  testWidgets('tabs switch between the three screens', (tester) async {
    final gateway = FakeCompanionGateway.paired(sessions: [summary('s1')]);
    await pumpPhone(tester, gateway: gateway, home: const CompanionShell());

    expect(find.text('Session s1'), findsOneWidget);

    await tester.tap(find.text('Inbox'));
    await tester.pumpAndSettle();
    expect(find.text('Nothing needs you.'), findsOneWidget);

    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('PAIRED DESKTOP'), findsOneWidget);
  });

  testWidgets('a lost link is a banner, and Retry asks for a reconnect', (
    tester,
  ) async {
    final gateway = FakeCompanionGateway.paired(sessions: [summary('s1')]);
    await pumpPhone(tester, gateway: gateway, home: const CompanionShell());
    expect(find.textContaining('Host unreachable'), findsNothing);

    gateway.setLink(CompanionLinkState.disconnected);
    await tester.pump();
    expect(find.textContaining('Host unreachable'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pump();
    await tester.pump();
    expect(gateway.reconnectRequests, 1);
    // The fake reconnects at once, so the banner clears.
    expect(find.textContaining('Host unreachable'), findsNothing);
  });

  testWidgets('a phone still dialling says WHY, and can be told to start '
      'over', (tester) async {
    // The state the owner was stuck in: "Connecting to your desktop…" with
    // nothing to act on. Dialling is not a reason to withhold the reason, and
    // not a reason to withhold the only control there is.
    final gateway = FakeCompanionGateway.paired(sessions: [summary('s1')]);
    await pumpPhone(tester, gateway: gateway, home: const CompanionShell());

    // The order is the real one, and it is the whole point: the phone starts
    // dialling FIRST and learns why only when a candidate fails — with the
    // link already `connecting`, so nothing about the link state changes when
    // the reason arrives. Setting the reason first would pass against a
    // banner that can only ever show it by accident.
    gateway.setLink(CompanionLinkState.connecting);
    await tester.pump();
    expect(find.textContaining('Connecting to your desktop'), findsOneWidget);

    gateway.linkTrouble = 'Your desktop is not answering on this relay.';
    await tester.pump();

    expect(find.textContaining('Connecting to your desktop'), findsOneWidget);
    expect(
      find.text('Your desktop is not answering on this relay.'),
      findsOneWidget,
      reason: 'the gateway knows why; the banner must say it',
    );

    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(gateway.reconnectRequests, 1);
  });
}
