import 'package:chitragupta/src/features/companion/client/fake_companion_gateway.dart';
import 'package:chitragupta/src/features/companion/presentation/pairing/pairing_screen.dart';
import 'package:chitragupta/src/features/companion/presentation/pairing/scan_qr_screen.dart';
import 'package:chitragupta/src/features/companion/presentation/pairing/short_code_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'companion_test_support.dart';

/// Pairing on the phone: the QR path (scanner injected — no camera in tests)
/// and the typed short-code fallback, happy and refused.
void main() {
  testWidgets('the pairing screen offers both ways in', (tester) async {
    await pumpPhone(
      tester,
      gateway: FakeCompanionGateway(),
      home: const PairingScreen(),
    );
    expect(find.text('Pair with your desktop'), findsOneWidget);
    expect(find.text('Scan the QR code'), findsOneWidget);

    await tester.tap(find.text('Type the code instead'));
    await tester.pumpAndSettle();
    expect(find.byType(ShortCodeScreen), findsOneWidget);
  });

  testWidgets('typing the right short code pairs', (tester) async {
    final gateway = FakeCompanionGateway(validShortCode: 'ABCD1234');
    await pumpPhone(tester, gateway: gateway, home: const ShortCodeScreen());

    await tester.enterText(find.byType(TextField), 'abcd1234');
    await tester.tap(find.widgetWithText(FilledButton, 'Pair'));
    await tester.pump();

    expect(gateway.pairing, isNotNull);
  });

  testWidgets('a refused short code shows the refusal and keeps the screen', (
    tester,
  ) async {
    final gateway = FakeCompanionGateway(validShortCode: 'ABCD1234');
    await pumpPhone(tester, gateway: gateway, home: const ShortCodeScreen());

    await tester.enterText(find.byType(TextField), 'WRONG000');
    await tester.tap(find.widgetWithText(FilledButton, 'Pair'));
    await tester.pump();

    expect(gateway.pairing, isNull);
    expect(find.textContaining('did not recognise that code'), findsOneWidget);
    // Still here to try again.
    expect(find.byType(ShortCodeScreen), findsOneWidget);
  });

  testWidgets('a scanned QR payload pairs through the gateway', (tester) async {
    final gateway = FakeCompanionGateway();
    late ValueChanged<String> deliver;
    await pumpPhone(
      tester,
      gateway: gateway,
      home: ScanQrScreen(
        scannerBuilder: (context, onPayload) {
          deliver = onPayload;
          return const Placeholder();
        },
      ),
    );

    deliver(
      '{"relay":"wss://r","rendezvous":"ab","version":1,'
      '"secret":"s3cret"}',
    );
    await tester.pump();

    expect(gateway.pairing, isNotNull);
  });

  testWidgets('a foreign QR code is refused in words and scanning resumes', (
    tester,
  ) async {
    final gateway = FakeCompanionGateway();
    late ValueChanged<String> deliver;
    await pumpPhone(
      tester,
      gateway: gateway,
      home: ScanQrScreen(
        scannerBuilder: (context, onPayload) {
          deliver = onPayload;
          return const Placeholder();
        },
      ),
    );

    deliver('https://example.com/some-other-qr');
    await tester.pump();

    expect(gateway.pairing, isNull);
    expect(
      find.textContaining('not a Chitragupta pairing code'),
      findsOneWidget,
    );

    // A later, valid code still works — one bad scan must not wedge the screen.
    deliver('{"secret":"s3cret"}');
    await tester.pump();
    expect(gateway.pairing, isNotNull);
  });
}
