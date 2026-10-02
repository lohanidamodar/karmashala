/// The pairing-relay field on the companion settings screen: shows the
/// current value, applies edits through the gateway, and resets to the
/// default on an emptied field — reachable paired and unpaired alike.
library;

import 'package:karmashala_remote/companion.dart';
import 'package:karmashala_companion/screens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'companion_test_support.dart';

void main() {
  Finder relayField() => find.ancestor(
    of: find.text('PAIRING RELAY'),
    matching: find.byType(Column),
  );

  testWidgets('shows the default, applies an edit, resets on empty', (
    tester,
  ) async {
    final gateway = FakeCompanionGateway.paired();
    await pumpPhone(
      tester,
      gateway: gateway,
      home: const CompanionSettingsScreen(),
    );
    await tester.pumpAndSettle();

    expect(find.text('PAIRING RELAY'), findsOneWidget);
    final field = find.descendant(
      of: relayField().first,
      matching: find.byType(TextField),
    );
    expect(
      tester.widget<TextField>(field).controller?.text,
      kDefaultCompanionRelayUrl,
    );

    await tester.enterText(field, 'wss://my.relay.example');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(await gateway.pairingRelay(), Uri.parse('wss://my.relay.example'));

    await tester.enterText(field, '');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(await gateway.pairingRelay(), defaultCompanionRelay);
    expect(
      tester.widget<TextField>(field).controller?.text,
      kDefaultCompanionRelayUrl,
      reason: 'the field shows what the default is, not an empty box',
    );
  });

  testWidgets('a URL without a scheme is refused in words and not stored', (
    tester,
  ) async {
    final gateway = FakeCompanionGateway.paired();
    await pumpPhone(
      tester,
      gateway: gateway,
      home: const CompanionSettingsScreen(),
    );
    await tester.pumpAndSettle();

    final field = find.descendant(
      of: relayField().first,
      matching: find.byType(TextField),
    );
    await tester.enterText(field, 'not a url');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(find.textContaining('Enter a full URL'), findsOneWidget);
    expect(await gateway.pairingRelay(), defaultCompanionRelay);
  });

  testWidgets('the unpaired settings screen still offers the relay field — '
      'exactly when the next typed code needs it', (tester) async {
    final gateway = FakeCompanionGateway();
    await pumpPhone(
      tester,
      gateway: gateway,
      home: const CompanionSettingsScreen(),
    );
    await tester.pumpAndSettle();

    expect(find.text('Not paired.'), findsOneWidget);
    expect(find.text('PAIRING RELAY'), findsOneWidget);
  });
}
