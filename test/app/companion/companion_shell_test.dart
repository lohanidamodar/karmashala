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
    expect(find.text('Sessions'), findsWidgets);
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
    expect(find.text('1'), findsOneWidget);
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
}
