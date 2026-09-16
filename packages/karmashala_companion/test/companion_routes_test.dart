import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_companion/pairing.dart';
import 'package:karmashala_companion/screens.dart';
import 'package:karmashala_companion/src/presentation/pairing/add_machine_screen.dart';
import 'package:karmashala_companion/widgets.dart';
import 'package:karmashala_remote/companion.dart';
import 'package:karmashala_remote/pairing.dart' show PairingCode;

import 'companion_test_support.dart';

final _typedCode = PairingCode.encode(List<int>.generate(20, (i) => i));

/// Every companion screen arrives by the one companion transition, never by
/// Material's whole-page zoom.
void main() {
  void arrivedByCompanionRoute(WidgetTester tester, Type screen) {
    final route = ModalRoute.of(tester.element(find.byType(screen)));
    expect(route, isA<PageRouteBuilder<void>>(), reason: '$screen');
    expect(route, isNot(isA<MaterialPageRoute<void>>()), reason: '$screen');
  }

  testWidgets('the pairing screen opens the code and machine screens', (
    tester,
  ) async {
    await pumpPhone(
      tester,
      gateway: FakeCompanionGateway(),
      home: const PairingScreen(),
    );

    await tester.tap(find.text('Paste the code instead'));
    await tester.pumpAndSettle();
    arrivedByCompanionRoute(tester, ShortCodeScreen);

    Navigator.of(tester.element(find.byType(ShortCodeScreen))).pop();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add a machine by address'));
    await tester.pumpAndSettle();
    arrivedByCompanionRoute(tester, AddMachineScreen);
  });

  testWidgets('a typed code opens its progress screen', (tester) async {
    await pumpPhone(
      tester,
      gateway: FakeCompanionGateway(),
      home: const ShortCodeScreen(),
    );
    await tester.enterText(find.byType(TextField), _typedCode);
    await tester.tap(find.widgetWithText(FilledButton, 'Pair'));
    await tester.pumpAndSettle();
    arrivedByCompanionRoute(tester, PairingProgressScreen);
  });

  testWidgets('a machine address opens its progress screen', (tester) async {
    await pumpPhone(
      tester,
      gateway: FakeCompanionGateway(),
      home: const AddMachineScreen(),
    );
    await tester.enterText(find.byType(TextField).at(0), '203.0.113.9');
    await tester.enterText(find.byType(TextField).at(1), _typedCode);
    await tester.tap(find.widgetWithText(FilledButton, 'Pair'));
    await tester.pumpAndSettle();
    arrivedByCompanionRoute(tester, PairingProgressScreen);
  });

  testWidgets('the scan screen opens progress and the code screen', (
    tester,
  ) async {
    late ValueChanged<String> deliver;
    await pumpPhone(
      tester,
      gateway: FakeCompanionGateway(),
      home: ScanQrScreen(
        scannerBuilder: (context, onPayload) {
          deliver = onPayload;
          return const Placeholder();
        },
      ),
    );
    deliver('{"relay":"wss://r","rendezvous":"ab","version":1,"secret":"s"}');
    await tester.pumpAndSettle();
    arrivedByCompanionRoute(tester, PairingProgressScreen);

    Navigator.of(tester.element(find.byType(PairingProgressScreen))).pop();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Type the code instead'));
    await tester.pumpAndSettle();
    arrivedByCompanionRoute(tester, ShortCodeScreen);
  });

  testWidgets('settings open diagnostics and a new pairing', (tester) async {
    await pumpPhone(
      tester,
      gateway: FakeCompanionGateway.paired(),
      home: Builder(
        builder: (context) => Column(
          children: [
            TextButton(
              onPressed: () => CompanionLogScreen.show(context),
              child: const Text('logs'),
            ),
            const ConnectionsSection(),
          ],
        ),
      ),
    );

    await tester.tap(find.text('logs'));
    await tester.pumpAndSettle();
    arrivedByCompanionRoute(tester, CompanionLogScreen);
    Navigator.of(tester.element(find.byType(CompanionLogScreen))).pop();
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add a desktop'));
    await tester.pumpAndSettle();
    arrivedByCompanionRoute(tester, PairingScreen);
  });

  testWidgets('the desktop strip opens a new pairing', (tester) async {
    await pumpPhone(
      tester,
      gateway: FakeCompanionGateway.paired(),
      home: const Column(children: [HostSwitcherBar()]),
    );
    await tester.tap(find.byType(HostSwitcherBar));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add a desktop'));
    await tester.pumpAndSettle();
    arrivedByCompanionRoute(tester, PairingScreen);
  });
}
