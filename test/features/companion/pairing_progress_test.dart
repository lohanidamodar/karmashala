/// The pairing-progress additions to the gateway contract (stream, relay
/// setting, payload sniff in `pairWithCode`) driven through the fake, and the
/// progress screen's staged states, failure, Retry and Back.
library;

import 'package:chitragupta/src/features/companion/client/companion_gateway.dart';
import 'package:chitragupta/src/features/companion/client/fake_companion_gateway.dart';
import 'package:chitragupta/src/features/companion/client/pairing_input.dart';
import 'package:chitragupta/src/features/companion/presentation/pairing/pairing_progress_screen.dart';
import 'package:chitragupta/src/features/companion/presentation/pairing/scan_qr_screen.dart';
import 'package:chitragupta/src/features/companion/presentation/pairing/short_code_screen.dart';
import 'package:chitragupta/src/features/remote/application/remote_access_controller.dart';
import 'package:chitragupta/src/features/remote/pairing/pairing_code.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'companion_test_support.dart';

const _payload = '{"secret":"s3cret"}';
final _typedCode = PairingCode.encode(List<int>.generate(20, (i) => i));

void main() {
  group('the gateway contract additions (fake)', () {
    test('a pairing attempt narrates codeAccepted → searching → proving → '
        'paired', () async {
      final gateway = FakeCompanionGateway();
      final stages = <CompanionPairingStage>[];
      final sub = gateway.pairingProgress.listen((p) => stages.add(p.stage));

      await gateway.pairWithCode(gateway.validShortCode);
      await sub.cancel();

      expect(stages, [
        CompanionPairingStage.codeAccepted,
        CompanionPairingStage.searching,
        CompanionPairingStage.proving,
        CompanionPairingStage.paired,
      ]);
    });

    test('a refusal emits failed with the sentence', () async {
      final gateway = FakeCompanionGateway();
      final failures = <CompanionPairingProgress>[];
      final sub = gateway.pairingProgress.listen(failures.add);

      await expectLater(
        gateway.pairWithCode('WRONG000'),
        throwsA(isA<PairingException>()),
      );
      await sub.cancel();

      expect(failures.single.stage, CompanionPairingStage.failed);
      expect(failures.single.message, contains('did not recognise'));
    });

    test(
      'pairWithCode sniffs a pasted JSON payload apart from a code',
      () async {
        final gateway = FakeCompanionGateway();
        final paired = await gateway.pairWithCode(_payload);
        expect(paired, same(gateway.pairing));
      },
    );

    test('the pairing relay defaults to the same relay the desktop ships '
        'with, and is settable and resettable', () async {
      final gateway = FakeCompanionGateway();
      expect(await gateway.pairingRelay(), Uri.parse(kDefaultRelayUrl));
      expect(kDefaultCompanionRelayUrl, kDefaultRelayUrl);

      await gateway.setPairingRelay(Uri.parse('wss://my.relay.example'));
      expect(await gateway.pairingRelay(), Uri.parse('wss://my.relay.example'));

      await gateway.setPairingRelay(null);
      expect(await gateway.pairingRelay(), Uri.parse(kDefaultRelayUrl));
    });
  });

  group('the input sniff the screens use', () {
    test('tells payloads, typed codes and junk apart', () {
      expect(classifyPairingInput(_payload), PairingInputKind.payload);
      expect(classifyPairingInput(' $_payload '), PairingInputKind.payload);
      expect(classifyPairingInput(_typedCode), PairingInputKind.typedCode);
      expect(
        classifyPairingInput(_typedCode.toLowerCase().replaceAll('-', ' ')),
        PairingInputKind.typedCode,
      );
      expect(
        classifyPairingInput('https://example.com/qr'),
        PairingInputKind.unrecognised,
      );
      expect(classifyPairingInput('ABCD1234'), PairingInputKind.unrecognised);
      expect(classifyPairingInput(''), PairingInputKind.unrecognised);
    });
  });

  group('the progress screen', () {
    testWidgets('walks the stages to paired, with the host and grant named', (
      tester,
    ) async {
      final gateway = FakeCompanionGateway(
        pairDelay: const Duration(milliseconds: 200),
      );
      await pumpPhone(
        tester,
        gateway: gateway,
        home: PairingProgressScreen(
          attempt: (g) => g.pairWithCode(gateway.validShortCode),
        ),
      );

      expect(find.text('Code accepted'), findsOneWidget);
      expect(find.text('Proving keys'), findsOneWidget);
      expect(find.textContaining('Looking for your desktop'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 250));
      expect(
        find.textContaining('on this network and over the relay'),
        findsOneWidget,
        reason: 'the searching stage says which paths are being tried',
      );

      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Paired with Desktop'), findsOneWidget);
      expect(find.textContaining('This phone may:'), findsOneWidget);
      expect(find.text('Start using this phone'), findsOneWidget);
      expect(gateway.pairing, isNotNull);
    });

    testWidgets('a failure is its own state, with Retry and Back', (
      tester,
    ) async {
      final gateway = FakeCompanionGateway();
      await pumpPhone(
        tester,
        gateway: gateway,
        home: PairingProgressScreen(attempt: (g) => g.pairWithCode('WRONG000')),
      );
      await tester.pump();

      expect(find.textContaining('did not recognise'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('Back'), findsOneWidget);
      expect(gateway.pairing, isNull);

      // Retry re-runs the same attempt — still refused, still standing.
      await tester.tap(find.text('Retry'));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('did not recognise'), findsOneWidget);
    });
  });

  group('the screens route real codes through the progress screen', () {
    testWidgets('a scanned payload leaves the camera for the progress '
        'screen and pairs', (tester) async {
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

      deliver(_payload);
      await tester.pumpAndSettle();

      expect(find.byType(PairingProgressScreen), findsOneWidget);
      expect(find.text('Paired with Desktop'), findsOneWidget);
      expect(gateway.pairing, isNotNull);
    });

    testWidgets('a typed code leaves the input for the progress screen; its '
        'refusal shows there and Back returns cleanly', (tester) async {
      final gateway = FakeCompanionGateway();
      await pumpPhone(tester, gateway: gateway, home: const ShortCodeScreen());

      await tester.enterText(find.byType(TextField), _typedCode);
      await tester.tap(find.widgetWithText(FilledButton, 'Pair'));
      await tester.pumpAndSettle();

      // The fake knows no such code, so the attempt fails — on the progress
      // screen, not silently under the camera.
      expect(find.byType(PairingProgressScreen), findsOneWidget);
      expect(find.textContaining('did not recognise'), findsOneWidget);

      await tester.tap(find.text('Back'));
      await tester.pumpAndSettle();
      expect(find.byType(ShortCodeScreen), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        _typedCode,
        reason: 'coming back keeps what was typed',
      );
    });
  });
}
