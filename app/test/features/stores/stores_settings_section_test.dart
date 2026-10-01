import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/stores/application/store_credentials.dart';
import 'package:karmashala/src/features/stores/presentation/stores_settings_section.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';

/// Settings → Stores over the server: summaries of the keys it holds, never
/// a key; edited on a desktop, read-only on a phone.
void main() {
  final now = DateTime.utc(2026, 10, 1, 9);
  late FakeDataServer server;

  final apple = AppleKeySummary(
    keyId: 'KEYID',
    issuerId: 'issuer-uuid',
    vendorNumber: '8000',
    importedAt: DateTime.utc(2026, 9, 29),
  );
  final play = PlayAccountSummary(
    clientEmail: 'reader@example.iam',
    reportsBucket: 'pubsite_prod_rev_1',
    packageNames: const ['com.example.notes'],
    importedAt: DateTime.utc(2026, 9, 29),
  );

  Future<void> pump(WidgetTester tester, {required bool writable}) async {
    tester.view
      ..physicalSize = const Size(1200, 1600)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final data = await server.override();
    final container = ProviderContainer(
      overrides: [
        data,
        clockProvider.overrideWithValue(FixedClock(now)),
        storeCredentialsWritableProvider.overrideWithValue(writable),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: StoresSettingsSection()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  setUp(() {
    server = FakeDataServer(clock: () => now);
    server.stores.view = StoresView(apple: apple, play: play);
  });

  testWidgets('a desktop shows what the server holds and can change it', (
    tester,
  ) async {
    await pump(tester, writable: true);

    expect(tester.takeException(), isNull);
    expect(server.requests, contains(StoresGet.name));
    expect(find.text('KEYID'), findsOneWidget);
    expect(find.text('reader@example.iam'), findsOneWidget);
    expect(
      find.textContaining('kept by the Karmashala server'),
      findsOneWidget,
    );
    expect(find.textContaining('Karmashala tools'), findsOneWidget);
    expect(find.text('Save vendor number'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Remove'), findsNWidgets(2));

    await tester.enterText(
      find.widgetWithText(TextField, 'Vendor number (optional)'),
      '9000',
    );
    await tester.tap(find.text('Save vendor number'));
    await tester.pumpAndSettle();

    expect(server.stores.view.apple?.vendorNumber, '9000');
    expect(server.stores.receivedKeys, isEmpty);
  });

  testWidgets('a phone shows the summaries read-only and says where keys are '
      'imported', (tester) async {
    await pump(tester, writable: false);

    expect(tester.takeException(), isNull);
    expect(find.text('KEYID'), findsOneWidget);
    expect(find.text('8000'), findsOneWidget);
    expect(find.text('pubsite_prod_rev_1'), findsOneWidget);
    expect(
      find.textContaining('imported in Karmashala on the desktop'),
      findsOneWidget,
    );
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Save vendor number'), findsNothing);
    expect(find.text('Remove'), findsNothing);
    expect(find.text('Replace'), findsNothing);
  });
}
