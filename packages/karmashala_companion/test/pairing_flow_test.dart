import 'package:karmashala_remote/companion.dart';
import 'package:karmashala_companion/pairing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dart:async';
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

    await tester.tap(find.text('Paste the code instead'));
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
      find.textContaining('not a Karmashala pairing code'),
      findsOneWidget,
    );

    // A later, valid code still works — one bad scan must not wedge the screen.
    deliver('{"secret":"s3cret"}');
    await tester.pump();
    expect(gateway.pairing, isNotNull);
  });

  testWidgets('the pairing screen is legible at 200% and offers both ways', (
    tester,
  ) async {
    await pumpPhone(
      tester,
      gateway: FakeCompanionGateway(),
      home: const PairingScreen(),
      textScale: 2.0,
    );

    expect(find.text('Pair with your desktop'), findsOneWidget);
    expect(find.text('Scan the QR code'), findsOneWidget);
    expect(find.text('Paste the code instead'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the pairing screen shown as a root has no back arrow; pushed '
      'from settings it does', (tester) async {
    await pumpPhone(
      tester,
      gateway: FakeCompanionGateway(),
      home: const PairingScreen(),
    );
    expect(find.byType(AppBar), findsNothing);

    await tester.tap(find.text('Paste the code instead'));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();

    // Now push a second copy over the first: a screen you arrived at from
    // somewhere has to show the way back to it.
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(builder: (_) => const PairingScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Add a desktop'), findsOneWidget);
    expect(find.byType(BackButton), findsOneWidget);
  });

  testWidgets('the typed-code screen sets the code above the caption step', (
    tester,
  ) async {
    await pumpPhone(
      tester,
      gateway: FakeCompanionGateway(),
      home: const ShortCodeScreen(),
      textScale: 2.0,
    );

    final field = tester.widget<TextField>(find.byType(TextField));
    final caption = Theme.of(
      tester.element(find.byType(TextField)),
    ).textTheme.bodySmall;
    expect(
      field.style?.fontSize,
      greaterThan(caption!.fontSize!),
      reason: 'a code read character by character is not caption text',
    );
    expect(tester.takeException(), isNull);
  });
}
